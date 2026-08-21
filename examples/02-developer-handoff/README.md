# 02 — Developer handoff

Where the platform layer ends and the application layer begins.

[`01-platform-quickstart/`](../01-platform-quickstart/) produced a `MicrovmImage`
and an image ARN. This example shows how that ARN reaches an application, and how
the application runs MicroVMs from it — without touching a custom resource.

## The shape of the handoff

```
platform namespace                          sandbox-app namespace
──────────────────                          ─────────────────────
MicrovmImage  ──┐
                ├── FieldExport ──────────► ConfigMap/microvm-runtime
iam.Role      ──┘                                    │
(execution role)                                     │ mounted at
                                                     │ /etc/microvm-runtime
                                                     ▼
                                              Deployment/sandbox-app
                                                     │
                                                     │ RunMicrovm
                                                     │ CreateMicrovmAuthToken
                                                     │ TerminateMicrovm
                                                     ▼
                                              MicroVMs (not K8s objects)
```

The contract between the two teams is three ConfigMap keys. The developer never
reads a `MicrovmImage`, needs no RBAC on `lambdamicrovms.services.k8s.aws`, and is
not coupled to how the image was built. The platform team can rebuild the image
and the ARN in the ConfigMap updates itself.

## Files

| File | Side | Purpose |
| --- | --- | --- |
| [`namespace.yaml`](namespace.yaml) | platform | The developer's namespace |
| [`execution-role.yaml`](execution-role.yaml) | platform | Role the MicroVM assumes at run time |
| [`field-exports.yaml`](field-exports.yaml) | platform | Publishes image ARN, image version and execution role ARN into the developer namespace |
| [`app-deployment.yaml`](app-deployment.yaml) | developer | Application that mounts the ConfigMap |
| [`run_session.py`](run_session.py) | developer | Runs a MicroVM, talks to it, terminates it |

## Prerequisites

- [`../01-platform-quickstart/`](../01-platform-quickstart/) applied, with
  `quickstart-image` in state `CREATED`.
- The [ACK IAM controller](https://github.com/aws-controllers-k8s/iam-controller)
  for the execution role.
- `enableCrossNamespace` left at its default of `true` in the controller's Helm
  values. The `FieldExport` writes across a namespace boundary and is rejected if
  this is disabled.

## Steps

**1. Create the developer namespace and the execution role.**

```bash
kubectl apply -f namespace.yaml
kubectl apply -f execution-role.yaml
kubectl wait --for=condition=ACK.ResourceSynced \
  roles.iam.services.k8s.aws/microvm-execution-role --timeout=2m
```

**2. Create the target ConfigMap, then apply the field exports.**

The ConfigMap has to exist first. A `FieldExport` patches its target and never
creates it, so without this step every export fails each reconcile with
`unable to get existing configmap: configmaps "microvm-runtime" not found`.

The exports themselves go in the same namespace as the `MicrovmImage` and the
`Role` they read from — a `FieldExport` can only reference a resource in its own
namespace.

```bash
kubectl create configmap microvm-runtime -n sandbox-app
kubectl apply -f field-exports.yaml
```

**3. Confirm the ConfigMap materialised in the developer namespace.**

```bash
kubectl get configmap microvm-runtime -n sandbox-app -o yaml
```

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: microvm-runtime
  namespace: sandbox-app
data:
  executionRoleARN: arn:aws:iam::123456789012:role/microvm-execution-role
  imageARN: arn:aws:lambda:us-east-1:123456789012:microvm-image:quickstart-image
  imageVersion: "1.0"
```

If a key is absent, check the exports:

```bash
kubectl describe fieldexport microvm-image-arn
```

A `FieldExport` produces nothing until its source path has a value, so an image
still in `CREATING` yields no `imageARN`.

Each export also carries an `ACK.Advisory` condition here, noting that the
cross-namespace write will require explicit opt-in in a future release. It is a
deprecation warning, not a failure — the write still happens.

**4. Run a session.**

[`run_session.py`](run_session.py) is the developer-side workflow in ~100 lines.
It reads the ConfigMap, calls `RunMicrovm`, waits for `RUNNING`, mints an auth
token, sends an HTTP request with the `X-aws-proxy-auth` header, and terminates
the MicroVM in a `finally` block.

In-cluster, with the ConfigMap mounted:

```bash
kubectl apply -f app-deployment.yaml
kubectl exec -n sandbox-app deploy/sandbox-app -- python3 run_session.py
```

Or locally, passing the values through the environment:

```bash
export IMAGE_ARN=$(kubectl get configmap microvm-runtime -n sandbox-app -o jsonpath='{.data.imageARN}')
export EXECUTION_ROLE_ARN=$(kubectl get configmap microvm-runtime -n sandbox-app -o jsonpath='{.data.executionRoleARN}')
export AWS_REGION=us-east-1

python3 run_session.py
```

```
==> RunMicrovm from arn:aws:lambda:us-east-1:123456789012:microvm-image:quickstart-image
    microvmId=microvm-01234567-89ab-cdef-0123-456789abcdef state=PENDING
    state=PENDING, waiting
==> RUNNING at 89abcdef-0123-4567-89ab-cdef01234567.lambda-microvm.us-east-1.on.aws
==> HTTP 200: {"status":"ok","path":"/","instanceId":"..."}
==> TerminateMicrovm microvm-01234567-89ab-cdef-0123-456789abcdef
```

The endpoint hostname is its own identifier — it is not derived from the MicroVM
ID, so read it from `endpoint` rather than constructing it.

## The fourth IAM role

The repository README describes three roles. This example introduces a fourth,
which is easy to miss: the **application's** role.

| Role | Assumed by | Needs |
| --- | --- | --- |
| Controller | ACK controller pod | `lambda:*Microvm*`, `iam:PassRole` |
| Build | Lambda, during image build | `s3:GetObject`, CloudWatch Logs writes |
| Execution | The MicroVM, at run time | Whatever the app inside the MicroVM does |
| **Application** | The developer's pod | `RunMicrovm`, `GetMicrovm`, `TerminateMicrovm`, `CreateMicrovmAuthToken`, `iam:PassRole` for the execution role |

The application role is what makes the developer side work without ACK. A
minimal policy:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "lambda:RunMicrovm",
        "lambda:GetMicrovm",
        "lambda:TerminateMicrovm",
        "lambda:CreateMicrovmAuthToken",
        "lambda:PassNetworkConnector"
      ],
      "Resource": "*"
    },
    {
      "Effect": "Allow",
      "Action": "iam:PassRole",
      "Resource": "arn:aws:iam::123456789012:role/microvm-execution-role"
    }
  ]
}
```

`iam:PassRole` is scoped to the single execution role, since the application only
ever passes that one. It carries no `iam:PassedToService` condition: `RunMicrovm`
does not populate that key, so a statement gated on it never matches and every
`RunMicrovm` call fails with `AccessDeniedException` naming `iam:PassRole`. Scoping
by role ARN is what constrains it. `RunMicrovm` also requires
`lambda:PassNetworkConnector`, for the same reason `CreateMicrovmImage` does — see
[Controller IAM permissions](../../docs/installation.md#controller-iam-permissions).

## Why this is not a custom resource

Nothing in `run_session.py` would be improved by becoming a `Microvm` CR, and
several things would get worse:

- **Latency.** `RunMicrovm` returns in seconds. A CR would add controller
  work-queue latency to every session.
- **Volume.** One object per session in etcd, each reconciled on the resync
  cycle.
- **Lifetime mismatch.** The default resync period is ten hours. A session that
  lasts five minutes is created and deleted without the controller ever
  reconciling it a second time.
- **Cleanup.** `run_session.py` terminates in a `finally` block. There is no
  Kubernetes object whose deletion would do this, and a leaked CR means a leaked
  MicroVM that is billed until its `maximumDurationInSeconds` expires.

See [When not to reach for a custom resource](../../README.md#when-not-to-reach-for-a-custom-resource).

For the narrow case where a `Microvm` custom resource *is* the right answer, see
[`../03-long-lived-microvm/`](../03-long-lived-microvm/).

## Cleaning up

```bash
kubectl delete -f app-deployment.yaml
kubectl delete -f field-exports.yaml
kubectl delete -f execution-role.yaml
kubectl delete -f namespace.yaml
```

Deleting a `FieldExport` does not delete the ConfigMap it wrote, so remove the
namespace to clean that up.
