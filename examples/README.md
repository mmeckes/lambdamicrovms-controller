# Examples

Runnable manifests and scripts for the ACK Lambda MicroVMs controller.

Every example is self-contained and states its prerequisites. Placeholders you
are expected to replace are written as `<angle-bracket>` values or use the
reserved documentation account ID `123456789012`.

## Conventions

- **Region.** Examples use `us-east-1`. Substitute your own region in resource
  ARNs, including the Lambda-managed base image and network connector ARNs.
- **Namespace.** Platform-owned resources are applied to whatever namespace you
  choose; examples do not hardcode one except where a cross-namespace handoff is
  the point of the example.
- **No secrets in manifests.** Where a sample needs sensitive input, it is
  referenced from a Kubernetes `Secret` rather than inlined.

## Index

### Platform / infrastructure

Declarative, reviewed, slow-changing. These belong in git.

| Example | What it shows |
| --- | --- |
| [`01-platform-quickstart/`](01-platform-quickstart/) | Build role and `MicrovmImage`, ending at `CREATED` with an image ARN to hand over |

### Developer / CI

| Example | What it shows |
| --- | --- |
| [`02-developer-handoff/`](02-developer-handoff/) | `FieldExport` publishing the image ARN into a developer namespace, and an application that runs MicroVMs from it without any custom resource |
| [`03-long-lived-microvm/`](03-long-lived-microvm/) | The one case where a `Microvm` custom resource is right, and why it does not generalise to per-session MicroVMs |
| [`04-features/`](04-features/) | Single-concern samples: logging, lifecycle hooks, run hook payloads, resource sizing |
| [`05-lifecycle/`](05-lifecycle/) | Day-two operations: rebuilding to a new image version, and adopting an existing image |
| [`ci/`](ci/) | Packaging an application artifact and uploading it to S3, as a CI step rather than a custom resource |
