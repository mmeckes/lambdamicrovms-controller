#!/usr/bin/env python3
"""Run a MicroVM for one session, talk to it, and terminate it.

This is the developer half of the workflow, and it is deliberately NOT a
Kubernetes custom resource. A session-scoped MicroVM lives for seconds or
minutes; the controller reconciles every ten hours. Modelling this as a CR would
put a request-path operation behind an infrastructure-path reconciler.

Everything the platform team provides arrives through a ConfigMap. This script
never reads a MicrovmImage, and needs no RBAC on ACK resources.

Run inside the cluster (IRSA or Pod Identity supplying credentials):
    python3 run_session.py

Or locally against a mounted/exported config:
    IMAGE_ARN=... EXECUTION_ROLE_ARN=... python3 run_session.py
"""
import os
import sys
import time
import urllib.request

import boto3

REGION = os.environ.get("AWS_REGION", "us-east-1")
CONFIG_PATH = "/etc/microvm-runtime"


def config(key: str, env: str, required: bool = True) -> str | None:
    """Read a value from the mounted ConfigMap, falling back to the environment."""
    path = os.path.join(CONFIG_PATH, key)
    if os.path.exists(path):
        with open(path) as handle:
            return handle.read().strip()
    value = os.environ.get(env)
    if not value and required:
        sys.exit(f"error: {key} not found at {path} and ${env} is unset")
    return value


def main() -> int:
    image_arn = config("imageARN", "IMAGE_ARN")
    execution_role_arn = config("executionRoleARN", "EXECUTION_ROLE_ARN")
    # Optional. Pinning to the version the platform team published means a
    # rebuild cannot change what this session runs mid-flight.
    image_version = config("imageVersion", "IMAGE_VERSION", required=False)

    lambda_microvms = boto3.client("lambda-microvms", region_name=REGION)
    connector = f"arn:aws:lambda:{REGION}:aws:network-connector:aws-network-connector"

    # 1. Run a MicroVM for this session. This is the operation that must happen
    #    at request speed, which is why it is an API call.
    print(f"==> RunMicrovm from {image_arn}")
    request_params = {
        "imageIdentifier": image_arn,
        "executionRoleArn": execution_role_arn,
        "ingressNetworkConnectors": [f"{connector}:ALL_INGRESS"],
        "egressNetworkConnectors": [f"{connector}:INTERNET_EGRESS"],
        "idlePolicy": {
            "autoResumeEnabled": True,
            "maxIdleDurationSeconds": 900,
            "suspendedDurationSeconds": 300,
        },
        # Hard cap on how long this session can live, independent of idleness.
        "maximumDurationInSeconds": 3600,
    }
    if image_version:
        request_params["imageVersion"] = image_version

    microvm = lambda_microvms.run_microvm(**request_params)
    microvm_id = microvm["microvmId"]
    print(f"    microvmId={microvm_id} state={microvm['state']}")

    try:
        # 2. Wait for RUNNING.
        deadline = time.monotonic() + 300
        while time.monotonic() < deadline:
            current = lambda_microvms.get_microvm(microvmIdentifier=microvm_id)
            state = current["state"]
            if state == "RUNNING":
                break
            if state in ("TERMINATING", "TERMINATED"):
                sys.exit(f"error: MicroVM entered {state}: "
                         f"{current.get('stateReason', 'no reason given')}")
            print(f"    state={state}, waiting")
            time.sleep(5)
        else:
            sys.exit("error: timed out waiting for RUNNING")

        endpoint = current["endpoint"]
        print(f"==> RUNNING at {endpoint}")

        # 3. Mint an auth token. Short-lived, per-session, minted on demand —
        #    which is exactly why auth tokens are not custom resources.
        token = lambda_microvms.create_microvm_auth_token(
            microvmIdentifier=microvm_id,
            expirationInMinutes=30,
            allowedPorts=[{"allPorts": {}}],
        )["authToken"]

        # 4. Send a request. Every request to the endpoint needs the token in
        #    the X-aws-proxy-auth header.
        request = urllib.request.Request(
            f"https://{endpoint}/",
            headers={"X-aws-proxy-auth": token},
        )
        with urllib.request.urlopen(request, timeout=30) as response:
            print(f"==> HTTP {response.status}: {response.read().decode()}")

    finally:
        # 5. Always terminate. The session is over; the MicroVM should not
        #    outlive it. Nothing else will clean this up — there is no
        #    Kubernetes object with an owner reference to garbage collect.
        print(f"==> TerminateMicrovm {microvm_id}")
        lambda_microvms.terminate_microvm(microvmIdentifier=microvm_id)

    return 0


if __name__ == "__main__":
    sys.exit(main())
