# 05 — Lifecycle

Day-two operations: shipping new code into an existing image, and bringing
images that already exist under the controller's management.

| File | Shows |
| --- | --- |
| [`rebuild-new-version.yaml`](rebuild-new-version.yaml) | Triggering a new image version by changing `codeArtifact.uri` |
| [`adopt-existing-image.yaml`](adopt-existing-image.yaml) | Adopting an image created outside ACK |

## Rebuilding to a new version

Updating a `MicrovmImage` does not replace it. It creates a new **image
version**. The image ARN is stable, so anything referring to the resource keeps
working while the version behind it advances.

The trigger is a spec change — normally pointing `codeArtifact.uri` at a newly
published artifact:

```bash
# Publish a new artifact (see ../ci/)
../ci/package-artifact.sh \
  --bucket <your-bucket-name> \
  --key "builds/app-${GIT_SHA}.zip" \
  --source ./my-app

# Point the image at it
kubectl patch microvmimage versioned-image --type=merge \
  -p "{\"spec\":{\"codeArtifact\":{\"uri\":\"s3://<your-bucket-name>/builds/app-${GIT_SHA}.zip\"}}}"
```

Watch three status fields:

```bash
kubectl get microvmimage versioned-image -o custom-columns=\
'STATE:.status.state,ACTIVE:.status.latestActiveImageVersion,FAILED:.status.latestFailedImageVersion' \
  --watch
```

```
STATE      ACTIVE   FAILED
UPDATED    1.0      <none>
UPDATING   1.0      <none>
UPDATED    2.0      <none>
```

**A failed rebuild is safe.** On failure, `state` becomes `UPDATE_FAILED` and
`latestFailedImageVersion` is set, but `latestActiveImageVersion` still points at
the last good build:

```
STATE           ACTIVE   FAILED
UPDATING        1.0      <none>
UPDATE_FAILED   1.0      2.0
```

Running MicroVMs are unaffected, and new MicroVMs continue to launch from
version `1.0`. You are never left without a usable image. Read the build logs,
fix the artifact, and patch again — updates are accepted from `UPDATE_FAILED`.

Updates are only accepted while `state` is `CREATED`, `UPDATED`, `CREATE_FAILED`
or `UPDATE_FAILED`. An image mid-build will not pick up a spec change until it
settles.

### Content-addressed keys versus a fixed key

`rebuild-new-version.yaml` uses a commit SHA in the object key rather than a
fixed `app.zip`. That is the approach worth defaulting to:

| | Content-addressed key | Fixed key |
| --- | --- | --- |
| Trigger | `codeArtifact.uri` changes, so the rebuild is automatic | Spec is unchanged, so nothing triggers a rebuild |
| Reviewability | The version bump is a visible diff in git | No diff to review |
| Rollback | Point back at the previous key | The old artifact has been overwritten |

With a fixed key you must force reconciliation some other way — annotating the
resource, for instance — and you lose the ability to roll back, because the
previous artifact no longer exists.

### Pinning consumers

`Microvm.spec.imageVersion` pins an instance to a specific version. Leave it
unset and each new MicroVM uses `latestActiveImageVersion`, which means a
rebuild changes what new MicroVMs run. Set it, and a rebuild has no effect until
you deliberately move the pin. Long-lived environments generally want the pin;
ephemeral sessions generally do not.

## Adopting an existing image

Adoption brings an image that already exists in AWS under management without
recreating it. Useful when migrating from CLI or CloudFormation-managed images,
or reattaching after a resource was deleted under a `retain` policy.

The `aws lambda-microvms` command below describes the operation and its
parameters, but the CLI does not ship this service yet (verified against aws-cli
`2.34.28`), so it cannot be run as written — call the API through an SDK instead.
See [the note in the repository README](../../README.md#reaching-a-running-microvm).

```bash
# An image created outside ACK
aws lambda-microvms create-microvm-image \
  --name existing-image \
  --code-artifact uri=s3://<your-bucket-name>/app.zip \
  --base-image-arn arn:aws:lambda:us-east-1:aws:microvm-image:al2023-1 \
  --build-role-arn arn:aws:iam::123456789012:role/microvm-build-role

# Bring it under management
kubectl apply -f adopt-existing-image.yaml

kubectl get microvmimage adopted-image \
  -o jsonpath='{.status.ackResourceMetadata.arn}{"\n"}'
```

Two annotations control this:

| Annotation | Values | Meaning |
| --- | --- | --- |
| `services.k8s.aws/adoption-policy` | `adopt-or-create` | Adopt if it exists, create it if not |
| | `adopt` | Adopt if it exists, otherwise fail with `AdoptedResourceNotFound` |
| `services.k8s.aws/adoption-fields` | JSON string | Identifies the existing resource. **Must contain `arn`**, e.g. `'{"arn": "arn:aws:lambda:us-east-1:123456789012:microvm-image:existing-image"}'` |

`adoption-fields` is a JSON **string**, so it must be quoted in YAML. Requires
the `ResourceAdoption` feature gate, which the chart enables by default.

`arn` is the only accepted key for this resource. `PopulateResourceFromAnnotation`
in [`pkg/resource/microvm_image/resource.go`](../../pkg/resource/microvm_image/resource.go)
reads `arn` and nothing else, so identifying the image by `name` fails immediately
with a terminal condition rather than falling back to a lookup:

```
ACK.Terminal=True   Error populating adoption fields: required field missing: arn
```

Get the ARN of the image you want to adopt from `ListMicrovmImages`.

On adoption the controller reads the live resource and patches spec from it, so
spec values in your manifest may be overwritten by what AWS reports. Reconcile
your manifest with the adopted state afterwards, or subsequent diffs will be
confusing.

Pair adoption with `services.k8s.aws/deletion-policy: retain`. Having just taken
ownership of a pre-existing resource, an accidental `kubectl delete` destroying
it is the last thing you want:

```bash
kubectl delete microvmimage adopted-image   # AWS image survives
```

## Cleaning up

```bash
kubectl delete -f rebuild-new-version.yaml
kubectl delete -f adopt-existing-image.yaml   # retained; delete in AWS separately
```
