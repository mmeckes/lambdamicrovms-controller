# Installation

The controller is distributed as a Helm chart and a container image in Amazon
ECR Public. Released versions are listed on the
[`lambdamicrovms-chart` gallery page](https://gallery.ecr.aws/aws-controllers-k8s/lambdamicrovms-chart);
pick the newest rather than copying a version out of this document, which will
fall behind.

## Controller IAM permissions

The controller needs its own IAM role — distinct from the roles Lambda assumes to
build an image or to run a MicroVM. The permissions it requires are checked into
this repository at
[`config/iam/recommended-inline-policy`](../config/iam/recommended-inline-policy):

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "lambda:CreateMicrovmImage",
        "lambda:UpdateMicrovmImage",
        "lambda:DeleteMicrovmImage",
        "lambda:GetMicrovmImage",
        "lambda:GetMicrovmImageVersion",
        "lambda:ListMicrovmImages",
        "lambda:RunMicrovm",
        "lambda:GetMicrovm",
        "lambda:TerminateMicrovm",
        "lambda:ListMicrovms",
        "lambda:TagResource",
        "lambda:UntagResource",
        "lambda:ListTags",
        "lambda:PassNetworkConnector"
      ],
      "Resource": "*"
    },
    {
      "Effect": "Allow",
      "Action": "iam:PassRole",
      "Resource": [
        "arn:aws:iam::123456789012:role/microvm-build-role",
        "arn:aws:iam::123456789012:role/microvm-execution-role"
      ]
    }
  ]
}
```

The `iam:PassRole` statement is what lets the controller hand a build role or an
execution role to Lambda when it creates a `MicrovmImage` or a `Microvm`. Without
it, resource creation fails even though every `lambda:` action is permitted.

Replace the two role ARNs with the build and execution roles you actually use. The
statement is scoped to them by ARN rather than granting `iam:PassRole` on `*`,
because the controller only ever passes these roles.

**Do not add an `iam:PassedToService` condition to this statement.** It is the
natural way to constrain `iam:PassRole` for ordinary Lambda functions, but the
MicroVMs operations do not populate that condition key, so a statement gated on it
never matches and every image build fails with:

```
AccessDeniedException: User: ... is not authorized to perform: iam:PassRole
on resource: ... because no identity-based policy allows the iam:PassRole action
```

Scoping by role ARN is what constrains the statement instead.

`lambda:PassNetworkConnector` is required alongside `iam:PassRole` by
`CreateMicrovmImage`, `UpdateMicrovmImage`, and `RunMicrovm`. The build container
needs outbound access to pull base layers and install packages, which is granted
through the default network connector.

Scope the first statement's `Resource` down from `*` to specific image and MicroVM
ARNs if your environment requires it. The permissions above are the minimum set of
API calls the controller makes; narrowing the resources it may act on is
independent of that.

Associate the role with the controller's service account using [IRSA][irsa] or
[EKS Pod Identity][pod-identity]. The chart creates a service account named
`ack-lambdamicrovms-controller`; for IRSA, annotate it with the role ARN as shown
below.

[irsa]: https://docs.aws.amazon.com/eks/latest/userguide/iam-roles-for-service-accounts.html
[pod-identity]: https://docs.aws.amazon.com/eks/latest/userguide/pod-identities.html

## Install the Helm chart

```bash
export SERVICE=lambdamicrovms
export RELEASE_VERSION=0.2.1   # latest at time of writing; check the gallery
export ACK_SYSTEM_NAMESPACE=ack-system
export AWS_REGION=us-east-1
export ACK_CONTROLLER_ROLE_ARN=arn:aws:iam::123456789012:role/ack-lambdamicrovms-controller

helm install \
  --namespace "$ACK_SYSTEM_NAMESPACE" --create-namespace \
  --set "aws.region=$AWS_REGION" \
  --set "serviceAccount.annotations.eks\.amazonaws\.com/role-arn=$ACK_CONTROLLER_ROLE_ARN" \
  ack-"$SERVICE"-controller \
  "oci://public.ecr.aws/aws-controllers-k8s/$SERVICE-chart" --version="$RELEASE_VERSION"
```

If you use EKS Pod Identity instead of IRSA, omit the `serviceAccount.annotations`
flag and create a pod identity association for the
`ack-lambdamicrovms-controller` service account in the release namespace.

Settings worth knowing about, all in
[`helm/values.yaml`](../helm/values.yaml):

| Value | Default | Notes |
| --- | --- | --- |
| `aws.region` | `""` | Region for AWS API calls. Set this. |
| `installScope` | `cluster` | Set to `namespace` and pair with `watchNamespace` to restrict the controller to specific namespaces. `watchNamespace` accepts a comma-separated list. |
| `watchSelectors` | `""` | Comma-separated `label=value` selectors to further filter which resources are reconciled. |
| `deletionPolicy` | `delete` | Set to `retain` to leave AWS resources intact when their custom resources are deleted. |
| `reconcile.defaultResyncPeriod` | `36000` | Ten hours. See [Division of responsibility](../README.md#division-of-responsibility). |
| `enableCrossNamespace` | `true` | Required for resource references, secret references, and field exports that cross namespace boundaries. |
| `leaderElection.enabled` | `false` | Enable before increasing `deployment.replicas` beyond 1. |

**Region availability.** Lambda MicroVMs is not available in every AWS Region.
This repository does not encode a region list, so check the
[Lambda MicroVMs documentation][microvms-guide] for current availability rather
than assuming a region works.

[microvms-guide]: https://docs.aws.amazon.com/lambda/latest/dg/lambda-microvms-guide.html

## Verify the installation

```bash
kubectl get pods -n ack-system
kubectl get crds | grep lambdamicrovms
```

You should see a running controller pod and two established custom resource
definitions:

```
microvmimages.lambdamicrovms.services.k8s.aws
microvms.lambdamicrovms.services.k8s.aws
```
