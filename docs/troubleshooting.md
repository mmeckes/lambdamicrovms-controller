# Troubleshooting

## Reading resource conditions

Every ACK resource carries conditions that say why it is in its current state.
Start here before anything else:

```bash
kubectl describe microvmimage my-image
kubectl get microvmimage my-image -o jsonpath='{.status.conditions}' | jq
```

| Condition | Meaning |
| --- | --- |
| `ACK.ResourceSynced` | The AWS resource matches the spec. For `MicrovmImage` this requires `state` in `CREATED`/`UPDATED`; for `Microvm`, `RUNNING`/`SUSPENDED`. |
| `ACK.Terminal` | The controller will not retry. The spec must change to make progress. |
| `ACK.Recoverable` | A transient failure; the controller will retry. |
| `ACK.ReferencesResolved` | All `*Ref` fields resolved to real resources. |
| `ACK.LateInitialized` | Server-side defaults have been written back into spec. |
| `ACK.Adopted` | The resource was adopted rather than created. |

Two error codes are treated as terminal for both resources:
`ValidationException` and `InvalidParameterValueException`. Seeing either in an
`ACK.Terminal` message means the request itself was rejected — retrying without
changing the spec will not help.

## Finding build logs

The controller reports *that* a build failed. Why it failed is in the build logs,
which the controller never sees:

```bash
aws logs tail /aws/lambda-microvms/<image-name> --follow
```

That is the default log group. If you set `logging.cloudWatch.logGroup`, look
there instead. This is the single most useful thing to check on
`CREATE_FAILED` — the failure is usually in your `Dockerfile`, not in Kubernetes.

## Common failures

**The image build fails immediately and the build role looks correct.**

Check that the trust policy allows `sts:TagSession` as well as `sts:AssumeRole`.
Lambda tags the session it creates, so `sts:AssumeRole` alone is not enough. This
is the most common setup error:

```bash
aws iam get-role --role-name <build-role> \
  --query 'Role.AssumeRolePolicyDocument.Statement[0].Action'
```

```json
["sts:AssumeRole", "sts:TagSession"]
```

**`ValidationException` mentioning the image name.**

`spec.name` must be unique within the AWS account and is immutable once set. Two
`MicrovmImage` resources with the same `spec.name` — even in different namespaces
or clusters — collide. To rename, delete and recreate; a CEL rule rejects the
edit otherwise.

**Editing a `Microvm` sets `ACK.Terminal` with `not implemented`.**

Expected. `Microvm` has no update operation, so every spec field is immutable in
practice. Delete the resource and create a new one. See
[Division of responsibility](../README.md#division-of-responsibility) for why the
resource is shaped this way.

**`spec.baseImageVersion` and `status.resolvedBaseImageVersion` disagree.**

Also expected, and not drift. You set the minor component; the service resolves a
full `MINOR.PATCH`. See
[Base image versions](resource-reference.md#base-image-versions).

**`AccessDenied` on create despite every `lambda:` action being allowed.**

The controller's policy is missing `iam:PassRole` — it needs to pass your build or
execution role to Lambda — or the statement is there but gated on an
`iam:PassedToService` condition, which the MicroVMs operations do not populate, so
it never matches. The error names `iam:PassRole` in both cases:

```
AccessDeniedException: ... not authorized to perform: iam:PassRole on resource:
arn:aws:iam::123456789012:role/microvm-build-role
```

Check which it is, then scope the statement by role ARN with no condition:

```bash
aws iam get-role-policy --role-name <controller-role> \
  --policy-name recommended-inline-policy
```

A missing `lambda:PassNetworkConnector` produces the same `AccessDeniedException`
shape naming that action instead. See
[Controller IAM permissions](installation.md#controller-iam-permissions).

**A `FieldExport` produces nothing.**

**The target ConfigMap must already exist.** A `FieldExport` patches its target;
it never creates it. If the ConfigMap is absent the export fails every reconcile
with

```
unable to get existing configmap: configmaps "microvm-runtime" not found
```

so create an empty one first — `kubectl create configmap microvm-runtime -n
<namespace>` — and let the exports fill in the keys.

Beyond that, a `FieldExport` writes nothing until its source path has a value, so
an image still in `CREATING` yields no ARN. It also cannot read a resource in
another namespace — it must live alongside its source. Cross-namespace *writes*
require `enableCrossNamespace`, which defaults to `true`; when the target is in
another namespace the export additionally reports an `ACK.Advisory` condition
warning that the behaviour will need explicit opt-in in a future release. That is
advisory only and does not stop the write.

**A MicroVM runs fine but produces no logs.**

Two causes, both silent — `RunMicrovm` succeeds and the MicroVM serves traffic
either way:

1. **`logging` was set on the `MicrovmImage` instead of the `Microvm`.** On an
   image the field configures the *build*; it does not redirect runtime output.
   Runtime logging is per MicroVM.
2. **The runtime log group does not exist.** It is not auto-created, unlike the
   default build group, because the execution role usually lacks
   `logs:CreateLogGroup`. Create it up front, or grant that action.

```bash
aws logs describe-log-groups --log-group-name-prefix <runtime-log-group>
```

Also confirm the execution role's `Resource` covers the group the `Microvm`
names. `/aws/lambda/microvms/*` and `/aws/lambda-microvms/*` differ by a single
character, and the *default build* group uses the hyphenated form, so a policy
copied from a build role will not match a runtime group under
`/aws/lambda/microvms/`.

**Resource references never resolve.**

Check `ACK.ReferencesResolved`. A `*Ref` points at a Kubernetes resource name, not
an AWS name, and the referenced resource must itself be synced first.

## Forcing a reconcile

The default resync period is ten hours
(`reconcile.defaultResyncPeriod: 36000`). If you have changed something outside
Kubernetes and want the controller to notice now, rather than waiting:

```bash
kubectl annotate microvmimage my-image reconcile-trigger="$(date +%s)" --overwrite
```

Any metadata change enqueues the resource. Lowering `defaultResyncPeriod`
globally is usually the wrong instinct — if you find yourself wanting
second-scale reconciliation, that is a signal the resource belongs on the
[developer side](../README.md#when-not-to-reach-for-a-custom-resource) of the
split rather than in a custom resource.

To watch what the controller is doing:

```bash
kubectl logs -n ack-system deploy/ack-lambdamicrovms-controller -f
```
