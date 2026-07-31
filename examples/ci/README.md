# CI — artifact packaging

[`package-artifact.sh`](package-artifact.sh) packages an application and its
`Dockerfile` into a zip and uploads it to Amazon S3, ready to be referenced by a
`MicrovmImage`'s `codeArtifact.uri`.

## Why this is a script and not a custom resource

Uploading an object to S3 is a data-plane operation. ACK reconciles control-plane
resources — it can create the bucket, but it cannot put your zip inside it, and
there is no custom resource that would make that appropriate.

More importantly, it should not try to. Artifact packaging happens at the pace of
code changes, on every commit. Image building happens at the pace of
infrastructure changes. Keeping packaging in CI puts each activity on the side of
the boundary where it belongs:

| | Owner | Trigger | Cadence |
| --- | --- | --- | --- |
| Package and upload `app.zip` | Developer / CI | Code commit | Minutes |
| Build the `MicrovmImage` from it | Platform team | Reviewed manifest change | Days |

See the [Division of responsibility](../../README.md#division-of-responsibility)
section of the repository README.

## Usage

With no `--source`, the script generates a small sample Node.js HTTP server so
you can get an image building before writing any application code:

```bash
./package-artifact.sh --bucket <your-bucket-name>
```

With your own application, pass a directory containing your code and a
`Dockerfile`:

```bash
./package-artifact.sh --bucket <your-bucket-name> --source ./my-app
```

Give each build a distinct key when you want a new image version per commit:

```bash
./package-artifact.sh \
  --bucket <your-bucket-name> \
  --key "builds/app-${GIT_SHA}.zip" \
  --source ./my-app
```

| Flag | Default | Purpose |
| --- | --- | --- |
| `--bucket` | *required* | Destination S3 bucket |
| `--key` | `app.zip` | Object key |
| `--source` | *generates a sample* | Directory containing your app and `Dockerfile` |
| `--region` | `$AWS_REGION` | Region for the S3 upload |

## Wiring it into a pipeline

The script is intentionally boring so it drops into any CI system. A GitHub
Actions job that publishes a new artifact per commit:

```yaml
- name: Package MicroVM artifact
  env:
    GIT_SHA: ${{ github.sha }}
  run: |
    examples/ci/package-artifact.sh \
      --bucket "$ARTIFACT_BUCKET" \
      --key "builds/app-${GIT_SHA}.zip" \
      --source ./my-app
```

What happens next depends on how you want image versions to work:

- **A new image version per commit.** Have the pipeline patch
  `codeArtifact.uri` on the `MicrovmImage`, or open a pull request that does. The
  platform team still reviews the change; the artifact is already published.
- **Rebuild from a stable key.** Overwrite the same object key. The image is only
  rebuilt when its spec changes, so you also need to touch the resource to
  trigger a build.

Both approaches are shown in [`../05-lifecycle/`](../05-lifecycle/).

## Snapshot compatibility

A MicroVM image is a snapshot of your fully initialized application, and every
MicroVM launched from it resumes from that same snapshot. Anything your process
computed once at startup is shared by every MicroVM.

This matters for unique values. If your application generates IDs, session
tokens, or cryptographic material, generate them **after** startup using your
language's cryptographically secure pseudorandom number generator, not at module
load time. The generated sample demonstrates the pattern: `crypto.randomUUID()`
runs per process rather than being baked into the snapshot.

If your application uses OpenSSL, prefer the Lambda base container image, which
includes a snapshot-compatible version. See
[MicroVM Images](https://docs.aws.amazon.com/lambda/latest/dg/microvms-images.html)
in the AWS documentation.
