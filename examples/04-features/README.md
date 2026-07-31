# 04 — Features

Single-concern samples, each isolating one part of the resource surface. All are
platform-owned configuration.

| File | Shows |
| --- | --- |
| [`logging.yaml`](logging.yaml) | CloudWatch log groups, and the `disabled: {}` empty-map form |
| [`hooks.yaml`](hooks.yaml) | Build hooks (`ready`, `validate`) and lifecycle hooks (`run`, `suspend`, `resume`, `terminate`) |
| [`run-hook-payload.yaml`](run-hook-payload.yaml) | Per-MicroVM init data delivered from a Kubernetes `Secret` |
| [`resources-and-cpu.yaml`](resources-and-cpu.yaml) | Memory baselines, ARM_64, egress connectors, environment variables |

These are illustrative fragments rather than a sequence — apply whichever is
relevant. Each assumes the build role from
[`../01-platform-quickstart/`](../01-platform-quickstart/) and needs
`<your-bucket-name>` replaced.

## Logging

`logging` takes exactly one of two forms:

```yaml
logging:
  cloudWatch:
    logGroup: /aws/lambda/microvms/my-image
    logStream: builds          # optional
```

```yaml
logging:
  disabled: {}                 # an empty map, NOT `disabled: true`
```

The empty map is generated from an empty API shape. `disabled: true` is rejected
by the schema. If you omit `logging` altogether, build logs still go to
`/aws/lambda/microvms/<image-name>`.

## Hooks

Hooks are HTTP endpoints your application serves on `hooks.port`. The service
calls them and waits up to the matching timeout.

| Family | Hook | When | Typical use |
| --- | --- | --- | --- |
| `microvmImageHooks` | `ready` | During build | Signal that initialization finished and it is safe to snapshot |
| | `validate` | During build | Self-check before the image is marked `CREATED` |
| `microvmHooks` | `run` | MicroVM start | Per-instance init; receives `runHookPayload` as the body |
| | `suspend` | Before suspension | Flush external state |
| | `resume` | After resuming | Reopen connections, handle clock jumps |
| | `terminate` | Before termination | Best-effort final persistence |

Each is `ENABLED` or `DISABLED`; omitting one is equivalent to `DISABLED`.

**Start with `ready`.** Without it the builder has to infer when your application
has finished initializing, and a snapshot taken too early gives every MicroVM a
half-started process. This is the most common cause of an image that builds
successfully but misbehaves at run time.

Two cautions:

- **`run` is on the critical path of every MicroVM start.** Its duration is added
  to the start latency that the snapshot mechanism exists to avoid. Keep it short.
- **`terminate` is best-effort.** It does not run on abrupt termination, so it is
  not a durability mechanism.

## Run hook payloads

`runHookPayload` is a `SecretKeyReference` — `{name, key, namespace}`, with `key`
required. You cannot inline a literal string. The payload is the natural home for
per-tenant configuration, so the API only offers the secure form.

It requires `hooks.microvmHooks.run: ENABLED` on the **image**. With the run hook
disabled the payload is never delivered, silently.

Maximum 16,384 bytes.

Note the boundary here: `run-hook-payload.yaml` shows the platform-managed case,
where a long-lived MicroVM gets fixed initialization data. For genuinely
per-session payloads, pass `runHookPayload` to `RunMicrovm` from application code
— see [`../02-developer-handoff/`](../02-developer-handoff/).

## Resources and architecture

**`ARM_64` is the only supported architecture**, running on Graviton. Your
`Dockerfile` and all its dependencies must be ARM-compatible. Multi-arch base
images handle this transparently; an x86-only binary fails at build time.

**`minimumMemoryInMiB` is a baseline, not a limit.** A MicroVM can vertically
scale to 4x its baseline during peak activity. You pay the baseline rate while
running, and only for actual use above it — so size for average load rather than
peak. Over-provisioning the baseline costs money continuously; bursting costs
money only when it happens.

`resources`, `egressNetworkConnectors`, and `baseImageVersion` are all
late-initialized. Omit them and the service defaults are written back into spec
rather than appearing as perpetual drift.
