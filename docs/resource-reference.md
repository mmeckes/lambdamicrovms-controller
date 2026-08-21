# Resource reference

Both resources are in the `lambdamicrovms.services.k8s.aws/v1alpha1` API group.
The authoritative schemas are the generated types in
[`apis/v1alpha1`](../apis/v1alpha1) and the CRD manifests in
[`config/crd/bases`](../config/crd/bases).

## MicrovmImage

**Owner: platform team.** An image is built infrastructure — versioned, reviewed,
and shared by many MicroVMs.

Required: `name`, `baseImageARN`, `codeArtifact`.

| Spec field | Type | Notes |
| --- | --- | --- |
| `name` | string | **Required. Immutable** — enforced by a CEL rule (`self == oldSelf`). Must be unique within the AWS account. Pattern `^[a-zA-Z0-9-_]+$`. |
| `baseImageARN` | string | **Required.** Lambda-managed base image, e.g. `arn:aws:lambda:us-east-1:aws:microvm-image:al2023-1`. Discover with the `ListManagedMicrovmImages` operation. |
| `codeArtifact.uri` | string | **Required.** S3 URI of the zip containing your application and `Dockerfile`. |
| `baseImageVersion` | string | Optional. Omit for "use latest". See [Base image versions](#base-image-versions). |
| `buildRoleARN` | string | Role Lambda assumes to build the image. |
| `buildRoleRef` | reference | Alternative to `buildRoleARN`: reference an `iam.services.k8s.aws` `Role` by Kubernetes name. |
| `additionalOsCapabilities` | []string | Extra OS capabilities. Only supported value is `ALL`. |
| `cpuConfigurations[].architecture` | []object | Only supported value is `ARM_64`. |
| `description` | string | Free-form description. |
| `egressNetworkConnectors` | []string | Outbound connectors available at run time. Defaults to `[INTERNET_EGRESS]` server-side. |
| `environmentVariables` | map[string]string | Set in the MicroVM runtime environment. Not a secret mechanism — use `runHookPayload` on `Microvm` for sensitive per-instance data. |
| `hooks` | object | Build and lifecycle hooks: `microvmImageHooks` (`ready`, `validate`) and `microvmHooks` (`run`, `resume`, `suspend`, `terminate`), plus the `port` your application listens on. See [`examples/04-features/hooks.yaml`](../examples/04-features/hooks.yaml). |
| `logging` | object | `cloudWatch` or `disabled`. See [Logging configuration](#logging-configuration). |
| `resources[].minimumMemoryInMiB` | []object | Baseline memory. Defaults to `2048` server-side. |
| `tags` | map[string]string | Supported on images. |

| Status field | Notes |
| --- | --- |
| `state` | `CREATING`, `CREATED`, `CREATE_FAILED`, `UPDATING`, `UPDATED`, `UPDATE_FAILED`, `DELETING`, `DELETED`, `DELETE_FAILED` |
| `imageVersion` | Version of the image. |
| `latestActiveImageVersion` | Most recent version that built successfully. This is what MicroVMs run. |
| `latestFailedImageVersion` | Most recent version that failed to build, if any. |
| `resolvedBaseImageVersion` | Read-only, fully resolved `MINOR.PATCH` base image version. |
| `createdAt`, `updatedAt` | Timestamps. |
| `ackResourceMetadata.arn` | The image ARN. This is the resource's primary key. |

The controller gates on `state`:

| Behaviour | States |
| --- | --- |
| Considered synced | `CREATED`, `UPDATED` |
| Accepts updates | `CREATED`, `UPDATED`, `CREATE_FAILED`, `UPDATE_FAILED` |
| Accepts deletion | `CREATED`, `UPDATED`, `CREATE_FAILED`, `UPDATE_FAILED`, `DELETE_FAILED` |

A `MicrovmImage` sitting in `CREATING` is not stuck; builds take minutes. Watch
`state`, and on `CREATE_FAILED` read the build logs.

### Base image versions

`baseImageVersion` is the one field whose spec and status will legitimately
disagree, and it is worth understanding before it surprises you.

You set only the **minor** component, for example `"0"`. The builder owns the
patch component. The service resolves your input to a full `MINOR.PATCH` value
such as `"0.0"`, which is surfaced read-only as
`status.resolvedBaseImageVersion`.

The controller deliberately does not write the resolved value back into spec. If
it did, the next update would send `"0.0"` as the requested version, the request
validator would reject it, and the resource would be wedged. This is implemented
by dropping `BaseImageVersion` from the create and update output shapes in
[`generator.yaml`](../generator.yaml).

So: `spec.baseImageVersion: "0"` alongside
`status.resolvedBaseImageVersion: "0.0"` is correct and stable, not drift.

### Logging configuration

`logging` accepts exactly one of two forms. The `disabled` variant is an empty
object, which is unusual enough to trip people up:

```yaml
# Stream to a specific log group
logging:
  cloudWatch:
    logGroup: /aws/lambda/microvms/my-image

# Or turn logging off entirely — note the empty map
logging:
  disabled: {}
```

Build logs default to `/aws/lambda-microvms/<image-name>`.

On a `MicrovmImage` this setting covers **build logs only**. It does not redirect
the runtime output of MicroVMs launched from the image — set `logging` on the
`Microvm` (or pass it to `RunMicrovm`) for that. Runtime log groups are not
auto-created, and a missing one fails silently: the MicroVM runs and its logs are
dropped. See
[Logging in `examples/04-features/`](../examples/04-features/README.md#logging).

## Microvm

**Owner: platform team, for long-lived instances only.** For per-session MicroVMs,
call `RunMicrovm` from application code instead — see
[Division of responsibility](../README.md#division-of-responsibility).

No fields are required at the CRD level, because `imageIdentifier` may be
satisfied either directly or through `imageIdentifierRef`. In practice you must
supply one of the two.

| Spec field | Type | Notes |
| --- | --- | --- |
| `imageIdentifier` | string | Image ARN or ID to run. Supply this or `imageIdentifierRef`. |
| `imageIdentifierRef` | reference | Reference a `MicrovmImage` by Kubernetes name; the controller resolves its ARN. |
| `imageVersion` | string | Pin a specific image version. Omit to use the latest active version. |
| `executionRoleARN` | string | Role assumed by the MicroVM at run time. |
| `executionRoleRef` | reference | Reference an `iam.services.k8s.aws` `Role` by Kubernetes name. |
| `ingressNetworkConnectors` | []string | Inbound. Lambda-managed: `arn:aws:lambda:<region>:aws:network-connector:aws-network-connector:ALL_INGRESS`. |
| `egressNetworkConnectors` | []string | Outbound. Lambda-managed: `...:INTERNET_EGRESS`. |
| `idlePolicy` | object | `autoResumeEnabled`, `maxIdleDurationSeconds`, `suspendedDurationSeconds`. Idle time is measured by inbound traffic through the MicroVM proxy endpoint. |
| `logging` | object | Same shape as on `MicrovmImage`. |
| `maximumDurationInSeconds` | int64 | Hard lifetime cap before the platform terminates the MicroVM. Valid range 1–28800 (8 hours). |
| `runHookPayload` | secret reference | Per-MicroVM init data delivered as the body of the `/run` lifecycle hook. A `SecretKeyReference`, not a literal — maximum 16,384 bytes. |

| Status field | Notes |
| --- | --- |
| `microvmID` | The MicroVM ID. Primary key, read-only, shown as the `MICROVM-ID` printer column. |
| `endpoint` | HTTPS endpoint. Requires an auth token — see [Reaching a running MicroVM](#reaching-a-running-microvm). |
| `imageARN` | ARN of the image this MicroVM was launched from. |
| `state` | `PENDING`, `RUNNING`, `SUSPENDING`, `SUSPENDED`, `TERMINATING`, `TERMINATED` |
| `stateReason` | Why the MicroVM is in its current state. |
| `startedAt`, `terminatedAt` | Timestamps. |

| Behaviour | States |
| --- | --- |
| Considered synced | `RUNNING`, `SUSPENDED` |
| Accepts deletion | `RUNNING`, `SUSPENDED` |

Two constraints that follow from the resource having no update operation:

- **Editing the spec produces a terminal error.** Every spec field is compared
  during reconciliation, and the update path returns `NotImplemented`, so the
  controller sets an `ACK.Terminal` condition. Delete and recreate to change
  configuration.
- **Tags are not supported.** `tags` is ignored for `Microvm`, unlike
  `MicrovmImage`. The chart's `resourceTags` values still apply to images.

Suspend and resume are not spec fields. Configure `idlePolicy` for automatic
behaviour, or call `suspend-microvm` and `resume-microvm` directly.

## Reaching a running MicroVM

`status.endpoint` gives you a URL, but every request to it requires an
authentication token — and **auth tokens are intentionally not custom
resources**. They are per-request credentials with a lifetime measured in
minutes, so they are minted through the API when needed.

```bash
MICROVM_ID=$(kubectl get microvm my-microvm -o jsonpath='{.status.microvmID}')
ENDPOINT=$(kubectl get microvm my-microvm -o jsonpath='{.status.endpoint}')

# authToken is a map of header name to value, not a bare string, so select the
# header you need out of it.
TOKEN=$(aws lambda-microvms create-microvm-auth-token \
  --microvm-identifier "$MICROVM_ID" \
  --expiration-in-minutes 30 \
  --allowed-ports '[{"allPorts":{}}]' \
  --query 'authToken."X-aws-proxy-auth"' --output text)

curl "https://$ENDPOINT/" -H "X-aws-proxy-auth: $TOKEN"
```

> **The `aws lambda-microvms` CLI service is not available yet.** As of aws-cli
> `2.34.28`, `aws lambda-microvms` fails with `Invalid choice`, and no MicroVMs
> operations appear under `aws lambda`. The `aws lambda-microvms ...` commands
> shown in this repository's documentation and under `examples/` describe the
> operations and their parameters, but you cannot run them as written today.
> Until the CLI ships the service, call the API through an AWS SDK — the
> operations are live on the standard Lambda endpoint
> (`lambda.<region>.amazonaws.com`, API version `2025-09-09`). The SDK module is
> `github.com/aws/aws-sdk-go-v2/service/lambdamicrovms` for Go and
> `@aws-sdk/client-lambda-microvms` for JavaScript.
> [`examples/02-developer-handoff/run_session.py`](../examples/02-developer-handoff/run_session.py)
> shows the SDK path, which is what application code should use regardless.

In a real application this happens in code, not in a shell. See
[`examples/02-developer-handoff/`](../examples/02-developer-handoff/) for the full
pattern, including how the platform team hands the image ARN to the application in
the first place.
