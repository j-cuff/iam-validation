# validate-iam

`validate-iam.sh` checks the AWS IAM and EKS configuration used to deploy
Spectro Cloud Palette VerteX on EKS. It supports static IAM user credentials,
STS role assumption, and EKS Pod Identity across the `aws`, `aws-us-gov`,
`aws-iso`, and `aws-iso-b` partitions.

The validator is diagnostic. It reads AWS and Kubernetes configuration,
simulates IAM policy decisions, and, in STS mode, creates short-lived tagged
role sessions. It does not create roles, attach policies, install add-ons, or
modify the cluster. Failed checks print a suggested `FIX`, but the script never
runs that remediation automatically.

## Requirements

- Bash
- AWS CLI with a configured profile and region
- `jq`
- `kubectl` and access to the management cluster for the optional Kubernetes
  checks in Pod Identity mode
- Permission for the active AWS identity to inspect the configured resources
  and run `iam:SimulatePrincipalPolicy`
- Permission to call `sts:AssumeRole` with session tags when using STS mode

## Quick start

Create the local configuration file, edit it, and run the validator:

```bash
cp validate-iam.conf.example validate-iam.conf
$EDITOR validate-iam.conf
./validate-iam.sh
```

`validate-iam.conf` is excluded from Git. The script looks for that file beside
`validate-iam.sh`, regardless of the directory from which it is launched.

Use a different configuration file with `CONFIG_FILE`:

```bash
CONFIG_FILE=/secure/path/production.conf ./validate-iam.sh
```

Override the configured authentication mode for one run by passing exactly one
argument:

```bash
./validate-iam.sh secret
./validate-iam.sh sts
./validate-iam.sh pod-identity
```

Before running, confirm that the profile resolves to the expected account and
region:

```bash
source ./validate-iam.conf
export AWS_PROFILE
aws sts get-caller-identity
aws configure get region
```

In Pod Identity mode, also confirm that the current Kubernetes context points
to the EKS management cluster named by `CLUSTER_NAME`:

```bash
kubectl config current-context
kubectl cluster-info
```

The script uses the current context; it does not update or switch kubeconfig
contexts.

## Configuration

`validate-iam.conf.example` is executable shell syntax and is sourced by both
scripts in this project. Only use a configuration file you trust.

| Variable | Example/default | Purpose |
| --- | --- | --- |
| `AWS_PROFILE` | `your-profile` | AWS CLI profile used for all AWS calls. The script exports this value as `AWS_PROFILE`. |
| `PARTITION` | `aws` | One of `aws`, `aws-us-gov`, `aws-iso`, or `aws-iso-b`. Used to construct resource ARNs. |
| `AUTH_MODE` | `pod-identity` | One of `secret`, `sts`, or `pod-identity`. A positional argument overrides this value for one run. |
| `CLUSTER_NAME` | `your-eks-cluster` | EKS management cluster used for AWS cluster checks. Set it to an empty string to skip those checks and the `palette-global-config` check. |
| `ACCOUNT_ID` | Empty | Account containing the local roles. When empty, it is resolved with `sts:GetCallerIdentity`. |
| `ROLE_ID_SUFFIX` | Empty | Optional suffix used by the example configuration to derive all three default role names. |
| `DEPLOYER_ROLE_NAME` | `SpectroCloudPaletteRole` | Palette/cloud-account role validated in STS and Pod Identity modes. |
| `HUBBLE_ROLE_NAME` | `SpectroCloudHubbleRole` | Hubble role validated in Pod Identity mode. |
| `IDENTITY_ROLE_NAME` | `SpectroCloudIdentityRole` | Palette identity role validated in Pod Identity mode. |
| `PERMISSION_PROFILE` | `minimum-dynamic` | One of `core`, `minimum-dynamic`, or `minimum-static`. Controls the Palette-role add-on actions checked in Pod Identity mode. |
| `PLACEMENT_MODE` | `dynamic` | One of `dynamic` or `static`. Controls the placement-specific EC2 actions checked. |
| `TARGET_ACCOUNT_ID` | Empty | Enables optional cross-account checks when set. |
| `CONFIG_FILE` | `validate-iam.conf` beside the script | Environment variable selecting another configuration file. |

The example derives role names from `ROLE_ID_SUFFIX`. For example:

```bash
ROLE_ID_SUFFIX="production"
```

produces:

```text
SpectroCloudPaletteRole-production
SpectroCloudHubbleRole-production
SpectroCloudIdentityRole-production
```

You can instead set `DEPLOYER_ROLE_NAME`, `HUBBLE_ROLE_NAME`, and
`IDENTITY_ROLE_NAME` explicitly.

If `PERMISSION_PROFILE` is omitted, the script derives
`minimum-${PLACEMENT_MODE}` for compatibility with older configurations.
`minimum-dynamic` requires `PLACEMENT_MODE="dynamic"`, and `minimum-static`
requires `PLACEMENT_MODE="static"`. The `core` profile may be used with either
placement mode.

## Authentication modes

The mode determines which principal is simulated and which specialized checks
run.

| Mode | Deployment principal | Additional behavior |
| --- | --- | --- |
| `secret` | The IAM user returned by the configured AWS profile | Rejects assumed-role, federated, and root caller ARNs. Skips role assumption and all Pod Identity checks. |
| `sts` | The role named by `DEPLOYER_ROLE_NAME` | Performs a real 15-minute `sts:AssumeRole` request with the `PaletteValidation=true` session tag. |
| `pod-identity` | The deployer, Hubble, and identity roles | Validates Pod Identity trust, role permissions, add-on state, associations, Kubernetes configuration, and runtime environment injection. |

For `secret` mode, `AWS_PROFILE` must use the same IAM user's access key that
Palette will store. A profile that assumes a role does not validate the static
credential principal and is rejected.

## Permission and placement profiles

`PLACEMENT_MODE` changes the EC2 permissions tested:

- `dynamic` includes VPC, subnet, route table, internet gateway, NAT gateway,
  address, and network-interface lifecycle actions.
- `static` adds `ec2:DeleteTags` and `ec2:DescribeTags` instead of the dynamic
  network-creation actions.

All modes also test the common EC2, core EKS, OIDC-provider, CAPA-role, and Auto
Scaling actions defined in the script.

In Pod Identity mode, `PERMISSION_PROFILE` changes only the Palette role's EKS
add-on action set:

| Profile | Add-on actions simulated on the Palette role |
| --- | --- |
| `core` | `DescribeAddonVersions`, `DescribeAddon`, `CreateAddon`, `DeleteAddon`, and `UpdateAddon` |
| `minimum-dynamic` | `DescribeAddonVersions`, `CreateAddon`, and `UpdateAddon` |
| `minimum-static` | `DescribeAddonVersions`, `CreateAddon`, and `UpdateAddon` |

The minimum profiles intentionally omit `eks:DescribeAddon` and
`eks:DeleteAddon` from the Palette-role check because those permissions belong
to Hubble or CAPA/controller roles in the minimum-permissions model.

## Checks performed

Before the numbered sections, pre-flight checks verify the AWS CLI and `jq`,
resolve the account when necessary, and print the selected account, partition,
cluster, placement mode, permission profile, authentication mode, and caller.
The numbered validation sections are:

1. **Credential baseline** — verifies `sts:GetCallerIdentity` with the active
   credentials.
2. **EKS deployment permissions** — simulates common and placement-specific
   EC2 permissions, core EKS permissions, OIDC-provider management, CAPA role
   access, and Auto Scaling discovery on the selected deployment principal.
   EKS add-on permissions are included only in Pod Identity mode.
3. **Pod Identity role trust** — in Pod Identity mode, confirms that all three
   roles exist and have an `Allow` trust statement for
   `pods.eks.amazonaws.com` with `sts:AssumeRole` and `sts:TagSession`.
4. **Pod Identity role permissions** — in Pod Identity mode, simulates Pod
   Identity management and `iam:PassRole` for the deployer role; IAM, EC2, EKS,
   and KMS read permissions for Hubble; and EKS Pod Identity, EC2, `GetRole`,
   and `PassRole` permissions for the identity role.
5. **STS validation** — in STS mode, attempts direct tagged role assumption
   into the configured deployer role.
6. **EKS cluster checks** — when `CLUSTER_NAME` is set, checks that the cluster
   is active and inspects its OIDC issuer/provider. In Pod Identity mode it also
   checks Kubernetes 1.24 or later, the `eks-pod-identity-agent` add-on, and the
   presence of the Hubble and identity service-account associations.
7. **Partition validation** — checks the applicable principal or role ARNs
   against `PARTITION`. GovCloud additionally checks the configured region and
   the GovCloud OIDC provider ARN.
8. **CAPA roles** — looks for the six standard
   `*.cluster-api-provider-aws.sigs.k8s.io` roles. Missing roles are warnings
   because Palette may create them when it manages the CloudFormation stack.
9. **Cross-account validation** — runs the mode-specific checks described
   below when `TARGET_ACCOUNT_ID` is set.
10. **Management-cluster ConfigMap** — in Pod Identity mode with
    `CLUSTER_NAME` set, checks `kube-system/palette-global-config` and its
    `managementClusterName` value.
11. **Runtime Pod Identity injection** — in Pod Identity mode, inspects the
    first matching Hubble and Palette identity pods for
    `AWS_CONTAINER_CREDENTIALS_FULL_URI` and
    `AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE`.

The Pod Identity association check verifies that associations exist for these
namespace and service-account pairs:

```text
hubble-system/spectro-hubble
palette-identity/palette-identity
```

It reports the associated role ARN, but the current script does not compare
that ARN with the configured expected role. Review the printed value.

## Optional cluster and runtime checks

Set `CLUSTER_NAME=""` when validating IAM before the management cluster exists.
This skips the AWS EKS cluster checks and the `palette-global-config` check.

In Pod Identity mode, the runtime pod check is independent of `CLUSTER_NAME`.
If `kubectl` is installed, it still queries the current context. It reports a
warning and skips when the workloads do not exist, no matching pod is found, or
the pod cannot be inspected. Once a matching pod is present, either missing AWS
credential environment variable is a failure.

The selectors used are:

```text
hubble-system:    app=spectro-hubble
palette-identity: app=palette-identity
```

## Cross-account behavior

Set `TARGET_ACCOUNT_ID` to enable cross-account validation:

- `secret` mode always skips cross-account checks.
- `sts` mode performs a real tagged `sts:AssumeRole` request into
  `DEPLOYER_ROLE_NAME` in the target account.
- `pod-identity` mode uses IAM policy simulation to check whether the local
  identity role can call `sts:AssumeRole` and `sts:TagSession` on the target
  deployer role, and whether the local Hubble role can call those actions on
  the target Hubble role.

Pod Identity cross-account checks simulate the local roles' permissions. They
do not make a live cross-account assumption and therefore do not prove that the
target roles' trust policies or external-ID conditions are correct.

## Using it after `eks-deploy up`

`eks-deploy` creates the IAM resources; `validate-iam` independently checks
them. Map the configuration values as follows:

| `eks-deploy/defaults.env` | `validate-iam/validate-iam.conf` |
| --- | --- |
| `PALETTE_ROLE_NAME` | `DEPLOYER_ROLE_NAME` |
| `HUBBLE_ROLE_NAME` | `HUBBLE_ROLE_NAME` |
| `IDENTITY_ROLE_NAME` | `IDENTITY_ROLE_NAME` |
| `PERMISSION_PROFILE` | `PERMISSION_PROFILE` |
| `PLACEMENT_MODE` | `PLACEMENT_MODE` |
| `CLUSTER_NAME` | `CLUSTER_NAME` |

For example:

```bash
AWS_PROFILE="production"
PARTITION="aws-us-gov"
AUTH_MODE="pod-identity"
CLUSTER_NAME="production-eks"
ACCOUNT_ID=""

DEPLOYER_ROLE_NAME="SpectroCloudPaletteRole-production"
HUBBLE_ROLE_NAME="SpectroCloudHubbleRole-production"
IDENTITY_ROLE_NAME="SpectroCloudIdentityRole-production"

PERMISSION_PROFILE="minimum-dynamic"
PLACEMENT_MODE="dynamic"
TARGET_ACCOUNT_ID=""
```

Confirm that both projects target the same AWS account, partition, region,
cluster, permission profile, placement mode, and role names.

## Results and exit status

Each completed check is reported as `PASS`, `WARN`, `FAIL`, or informational
output:

- `PASS` means the tested condition succeeded.
- `WARN` identifies a skipped, unavailable, optional, or potentially incorrect
  condition and does not increment the failure count.
- `FAIL` increments the failure count and normally includes a suggested `FIX`.

The script exits with:

- `0` when no checks fail;
- `1` for failed validation, invalid configuration, a missing configuration
  file, or a missing required tool;
- `2` when more than one positional argument is provided.

Warnings do not change the exit status. Because optional checks can warn and
skip, exit status `0` means every check that actually ran passed; it does not
mean every possible check ran.

## CAPA policy renderer

`render-capa-policy.sh` renders
`policies/capa-passrole-policy.template.json` with the partition and account
from the selected configuration. When `ACCOUNT_ID` is empty, it resolves the
account with STS.

Render the policy to standard output:

```bash
./render-capa-policy.sh
```

Use the same alternate configuration mechanism as the validator:

```bash
CONFIG_FILE=/secure/path/production.conf ./render-capa-policy.sh
```

To attach the rendered policy, first review it, then run an explicit AWS CLI
command such as:

```bash
source ./validate-iam.conf
export AWS_PROFILE

aws iam put-role-policy \
  --role-name "$DEPLOYER_ROLE_NAME" \
  --policy-name PaletteCAPAPassRole \
  --policy-document "$(./render-capa-policy.sh)" \
  --profile "$AWS_PROFILE"
```

The renderer itself does not attach or modify policies.

## Bundled policy examples

Files under `policies/` are reference material and possible remediation input.
The validator does not automatically load or apply them.

| File | Purpose |
| --- | --- |
| `capa-passrole-policy.template.json` | Account-neutral CAPA `GetRole`, `PassRole`, and `ListAttachedRolePolicies` template consumed by the renderer. |
| `deployer-trust-policy.json` | EKS Pod Identity trust example for the deployer role. |
| `deployerv2-passrole.json` | Pod Identity association, supported add-on, and broad `PassRole` permissions referenced by a deployer-role remediation. |
| `palette-identity-eks-policy.json` | Pod Identity, EC2, and role permissions example for the identity role. |
| `palette-identity-trust-policy.json` | EKS Pod Identity trust example for the identity role. |
| `sts-tag-session-policy.json` | Broad `sts:TagSession` permissions example. |
| `trust-policy.json` | Generic EKS Pod Identity trust example. |

Review and scope every policy before using it. In particular,
`palette-identity-eks-policy.json` contains a specific GovCloud account and
role ARN, while several examples use wildcard resources.

## Troubleshooting

- `implicitDeny` means no applicable allow statement grants the simulated
  action.
- `explicitDeny` means an applicable policy explicitly denies the action.
- A simulation error usually means the current caller lacks
  `iam:SimulatePrincipalPolicy`, the simulated role does not exist, or an ARN
  is invalid.
- A failed STS check can originate on either side: the caller must be allowed
  to assume and tag the session, and the target role must trust those actions.
- Missing Pod Identity environment variables commonly indicate a missing or
  incorrect association, an inactive agent add-on, or a pod created before the
  association was fixed. Restart the workload after correcting the setup.
- If simulation passes but a live operation is denied, inspect permissions
  boundaries, AWS Organizations service control policies, session policies,
  resource policies, and policy conditions. Simulation does not reproduce
  every part of a live authorization decision.
- If Kubernetes checks inspect the wrong resources, correct the active
  kubeconfig context and rerun the validator.

## Safety

Use a dedicated diagnostic identity with only the read, simulation, and
role-assumption permissions needed for the selected mode. Review output before
sharing it because account IDs, role ARNs, cluster names, OIDC issuers, and Pod
Identity associations may be displayed.

## References

- [Add an AWS account to Palette](https://docs.spectrocloud.com/clusters/public-cloud/aws/add-aws-accounts/)
- [Required IAM policies](https://docs.spectrocloud.com/clusters/public-cloud/aws/required-iam-policies/)
- [Minimum permissions policies](https://docs.spectrocloud.com/clusters/public-cloud/aws/required-iam-policies/minimum-permissions-policies/)
- [Core IAM policies](https://docs.spectrocloud.com/clusters/public-cloud/aws/required-iam-policies/core-iam-policies/)
- [Additional IAM policies](https://docs.spectrocloud.com/clusters/public-cloud/aws/required-iam-policies/additional-iam-policies-specific-use-cases/)
- [Amazon EKS Pod Identity](https://docs.aws.amazon.com/eks/latest/userguide/pod-identities.html)
- [IAM policy simulation](https://docs.aws.amazon.com/IAM/latest/UserGuide/access_policies_testing-policies.html)
