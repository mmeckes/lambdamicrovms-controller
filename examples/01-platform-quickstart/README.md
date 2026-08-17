# 01 — Platform quickstart

Build a MicroVM image declaratively, with the build role managed alongside it.

This example is deliberately **the platform half only**. It ends when the image
reaches `CREATED` and prints its ARN. It does not run a MicroVM, because running
MicroVMs is the developer's job — see
[`../02-developer-handoff/`](../02-developer-handoff/) for the other half, and the
[Division of responsibility](../../README.md#division-of-responsibility) section
of the repository README for why the line is drawn here.

## What gets created

| File | Resource | Purpose |
| --- | --- | --- |
| [`build-role.yaml`](build-role.yaml) | `iam.services.k8s.aws/Role` | Role Lambda assumes to build the image |
| [`microvmimage.yaml`](microvmimage.yaml) | `lambdamicrovms.services.k8s.aws/MicrovmImage` | The image itself |

## Prerequisites

- The ACK Lambda MicroVMs controller, installed and running
  ([installation](../../README.md#installation)).
- The [ACK IAM controller](https://github.com/aws-controllers-k8s/iam-controller),
  which reconciles the `Role` in `build-role.yaml`. If you would rather create the
  role out of band, skip that file and set `spec.buildRoleARN` on the image
  instead of `spec.buildRoleRef`.
- An S3 bucket, and a packaged artifact in it. Produce one with
  [`../ci/package-artifact.sh`](../ci/package-artifact.sh).

## Steps

**1. Package and upload your application.**

```bash
../ci/package-artifact.sh --bucket <your-bucket-name>
```

**2. Substitute the placeholders.**

`<your-bucket-name>` appears in both manifests, and the base image ARN in
`microvmimage.yaml` is written for `us-east-1`.

```bash
export BUCKET=<your-bucket-name>
export AWS_REGION=us-east-1

sed -i "s|<your-bucket-name>|$BUCKET|g; s|us-east-1|$AWS_REGION|g" \
  build-role.yaml microvmimage.yaml
```

**3. Apply the build role and wait for it.**

```bash
kubectl apply -f build-role.yaml
kubectl wait --for=condition=ACK.ResourceSynced \
  roles.iam.services.k8s.aws/microvm-build-role --timeout=2m
```

The resource type must be fully qualified. Plain `role/microvm-build-role`
resolves to the built-in RBAC `Role` instead, and fails with
`roles.rbac.authorization.k8s.io "microvm-build-role" not found`.

**4. Apply the image.**

```bash
kubectl apply -f microvmimage.yaml
```

**5. Watch the build.**

The image starts in `CREATING`. Lambda is running your `Dockerfile`, starting
your application, and snapshotting it, which takes several minutes.

```bash
kubectl get microvmimage quickstart-image \
  -o custom-columns='NAME:.metadata.name,STATE:.status.state,VERSION:.status.latestActiveImageVersion' \
  --watch
```

```
NAME               STATE      VERSION
quickstart-image   CREATING   <none>
quickstart-image   CREATED    1.0
```

Alternatively, block until the controller reports the resource synced, which
happens when `state` reaches `CREATED`:

```bash
kubectl wait --for=condition=ACK.ResourceSynced microvmimage/quickstart-image --timeout=15m
```

**6. Read the image ARN.**

This is the handoff artifact — the one value a developer needs in order to start
running MicroVMs.

```bash
kubectl get microvmimage quickstart-image \
  -o jsonpath='{.status.ackResourceMetadata.arn}'
```

## Verifying it worked

`spec.baseImageVersion` was left unset, so the service picked the latest base
image. The resolved version appears in status:

```bash
kubectl get microvmimage quickstart-image -o jsonpath='{.status.resolvedBaseImageVersion}'
```

The value is a full `MINOR.PATCH` pair — `1.0`, for instance — where the minor
component is whichever base image minor was latest at build time, so it changes
as new base images ship. A resolved value in status alongside an empty
`spec.baseImageVersion` is expected, and is not drift. See
[Base image versions](../../README.md#base-image-versions).

## If the build fails

`state` becomes `CREATE_FAILED`. The image build logs are in CloudWatch, in the
log group configured in `microvmimage.yaml`:

```bash
aws logs tail /aws/lambda/microvms/quickstart-image --follow
```

Check the resource conditions too:

```bash
kubectl describe microvmimage quickstart-image
```

The most common cause is the build role: either its trust policy is missing
`sts:TagSession`, or its `s3:GetObject` resource does not cover the artifact you
uploaded.

## Cleaning up

```bash
kubectl delete -f microvmimage.yaml
kubectl delete -f build-role.yaml
```

Deleting the `MicrovmImage` deletes the AWS image, because the chart's
`deletionPolicy` defaults to `delete`. Terminate any MicroVMs launched from the
image first.
