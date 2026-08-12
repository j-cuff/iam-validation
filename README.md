# validate-iam

`validate-iam` checks whether an AWS account and EKS management cluster have
the IAM configuration required to deploy and run Spectro Cloud Palette
VerteX. It validates role permissions, EKS Pod Identity trust, STS role
assumption, partition-specific ARNs, and—when cluster access is
available—live EKS and Kubernetes configuration.

The validator supports the `aws`, `aws-us-gov`, `aws-iso`, and `aws-iso-b`
partitions. GovCloud environments receive additional region and OIDC checks.

The script is diagnostic. It does not create roles, attach policies, install
add-ons, or modify the cluster. Failed checks include suggested remediation
commands for review; they are never executed automatically.

## What it validates

The script runs the following groups of checks:

1. AWS CLI and `jq` availability, AWS credentials, and caller identity.
2. Core or minimum EC2, EKS, IAM, OIDC, and Auto Scaling permissions for the selected authentication principal.
3. For Pod Identity, role trust and role-specific permissions for the deployer, Hubble, and Palette identity roles.
4. For STS, direct deployer-role assumption with session tags.
5. Optional live-cluster status and IAM OIDC provider checks.
6. Partition-correct ARNs and additional GovCloud configuration.
7. CAPA role naming and role existence.
8. Mode-appropriate optional cross-account validation.

Permission checks use the IAM policy simulator and do not create, update, or delete AWS resources. STS-mode checks create short-lived, tagged role sessions.

## Authentication modes

Set `AUTH_MODE` in `validate-iam.conf` to run only the checks relevant to the authentication method Palette uses.

| Mode | Principal validated | Mode-specific checks |
| --- | --- | --- |
| `secret` | IAM user represented by the configured static access key and secret key | Validates the current IAM user's deployment permissions. Role assumption and all Pod Identity checks are skipped. |
| `sts` | Role named by `DEPLOYER_ROLE_NAME` | Validates deployment permissions and performs `sts:AssumeRole` with a session tag. Pod Identity checks are skipped. |
| `pod-identity` | Palette, Hubble, and identity roles | Validates Pod Identity trust and permissions, the agent addon, service-account associations, Kubernetes configuration, and runtime environment injection. Direct caller-to-role assumption is skipped. |

Common account, deployment permission, cluster, partition, GovCloud, OIDC, and CAPA checks run in every mode.

In `secret` mode, `AWS_PROFILE` must resolve directly to the IAM user whose access key Palette stores. The validator rejects assumed-role, federated, and root callers in this mode so it does not report results for a different principal.

## Permission profiles

`PERMISSION_PROFILE` tells the validator which policy set was assigned to the
Palette/cloud-account role:

| Profile | Placement | Palette-role add-on permissions tested |
| --- | --- | --- |
| `core` | Selected separately with `PLACEMENT_MODE` | `DescribeAddonVersions`, `DescribeAddon`, `CreateAddon`, `DeleteAddon`, and `UpdateAddon` |
| `minimum-dynamic` | New workload VPCs may be created | `DescribeAddonVersions`, `CreateAddon`, and `UpdateAddon` |
| `minimum-static` | Workload clusters use existing VPCs | `DescribeAddonVersions`, `CreateAddon`, and `UpdateAddon` |

The minimum profiles intentionally do not require `eks:DescribeAddon` or
`eks:DeleteAddon` on the Palette role. Under Spectro's minimum model those
operations belong to Hubble or the CAPA/controller roles. This prevents false
failures against an `eks-deploy` `minimum-dynamic` or `minimum-static`
installation.

For backward compatibility, configurations without `PERMISSION_PROFILE`
derive `minimum-dynamic` or `minimum-static` from `PLACEMENT_MODE`. New
configurations should set both explicitly. A conflicting minimum profile and
placement mode is rejected before validation begins.

## Prerequisites

- Bash.
- [AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html), configured with working credentials and a default region.
- [`jq`](https://jqlang.github.io/jq/download/).
- For `pod-identity` mode, `kubectl` and access to the EKS management cluster. Kubernetes checks are skipped when `kubectl` is unavailable, and runtime checks warn and skip when no applicable workload pod exists yet.
- Permission for the current AWS identity to inspect the configured roles, simulate their policies, describe the EKS environment, and assume the roles being tested. In particular, policy simulation requires `iam:SimulatePrincipalPolicy`.

## Quick start

1. Create a local configuration file from the example:

   ```bash
   cp validate-iam.conf.example validate-iam.conf
   ```

2. Edit `validate-iam.conf` for the environment. At minimum, set the AWS
   profile, partition, authentication mode, cluster name, role names, and
   permission profile:

   ```bash
   AWS_PROFILE="your-profile"
   PARTITION="aws"
   AUTH_MODE="pod-identity"
   CLUSTER_NAME="your-eks-cluster"
   DEPLOYER_ROLE_NAME="SpectroCloudPaletteRole"
   HUBBLE_ROLE_NAME="SpectroCloudHubbleRole"
   IDENTITY_ROLE_NAME="SpectroCloudIdentityRole"
   PERMISSION_PROFILE="minimum-dynamic"
   PLACEMENT_MODE="dynamic"
   ```

   Use `PARTITION="aws-us-gov"` and a GovCloud AWS profile for GovCloud. To skip live EKS cluster checks, set `CLUSTER_NAME=""`. The local configuration file is excluded from Git.

3. Confirm the selected identity and region before running the validation:

   ```bash
   source ./validate-iam.conf
   export AWS_PROFILE
   aws sts get-caller-identity
   aws configure get region
   ```

4. Run the validator:

   ```bash
   ./validate-iam.sh
   ```

   To override `AUTH_MODE` for one run, pass the mode as the first argument:

   ```bash
   ./validate-iam.sh secret
   ./validate-iam.sh sts
   ./validate-iam.sh pod-identity
   ```

Each check is reported as `PASS`, `WARN`, or `FAIL`. Failed checks include a targeted `FIX` line with the relevant role, permission, resource, command, or configuration change. The script exits with status `0` when all required checks pass and status `1` when a prerequisite is missing or one or more checks fail. Warnings do not affect the exit status.

## Using it after `eks-deploy up`

`eks-deploy` creates the IAM identities; `validate-iam` independently checks
them. The two projects use different variable names for the Palette role, so
copy the values using this mapping:

| `eks-deploy/defaults.env` | `validate-iam/validate-iam.conf` |
| --- | --- |
| `PALETTE_ROLE_NAME` | `DEPLOYER_ROLE_NAME` |
| `HUBBLE_ROLE_NAME` | `HUBBLE_ROLE_NAME` |
| `IDENTITY_ROLE_NAME` | `IDENTITY_ROLE_NAME` |
| `PERMISSION_PROFILE` | `PERMISSION_PROFILE` |
| `CLUSTER_NAME` | `CLUSTER_NAME` |

`DEPLOYER_ROLE_NAME` is the validator's configuration name for the Palette
role. Set it to the same value as `PALETTE_ROLE_NAME` in `eks-deploy`. For
example, if `eks-deploy` created these roles:

```bash
PALETTE_ROLE_NAME="SpectroCloudPaletteRole-Example"
HUBBLE_ROLE_NAME="SpectroCloudHubbleRole-Example"
IDENTITY_ROLE_NAME="SpectroCloudIdentityRole-Example"
```

then configure the validator with:

```bash
DEPLOYER_ROLE_NAME="SpectroCloudPaletteRole-Example"
HUBBLE_ROLE_NAME="SpectroCloudHubbleRole-Example"
IDENTITY_ROLE_NAME="SpectroCloudIdentityRole-Example"
PERMISSION_PROFILE="minimum-dynamic"
PLACEMENT_MODE="dynamic"
```

Confirm that both projects target the same AWS account, partition, region,
and cluster before running the validator.

## Configuration

The script reads `validate-iam.conf` from its own directory by default. The
example file contains editable role-name examples; replace them with the roles
actually registered with Palette or created by `eks-deploy`. Values in the
selected configuration file are authoritative for that run.

| Variable | Default/current value | Description |
| --- | --- | --- |
| `AWS_PROFILE` | `your-profile` in the example | AWS CLI profile used for every AWS request. |
| `PARTITION` | `aws` | AWS partition: `aws`, `aws-us-gov`, `aws-iso`, or `aws-iso-b`. |
| `AUTH_MODE` | `pod-identity` | Authentication method: `secret`, `sts`, or `pod-identity`. |
| `CLUSTER_NAME` | `your-eks-cluster` in the example | EKS management cluster to inspect; use an empty string to skip live cluster checks. |
| `ACCOUNT_ID` | Resolved with STS | Account containing the roles being validated. |
| `DEPLOYER_ROLE_NAME` | Set explicitly | Palette/cloud-account role used by STS and Pod Identity modes; set it to `PALETTE_ROLE_NAME` from `eks-deploy`. |
| `HUBBLE_ROLE_NAME` | `spectro-hubble-role` | Hubble role used by Pod Identity mode. |
| `IDENTITY_ROLE_NAME` | `palette-identity-role` | Palette identity role used by Pod Identity mode. |
| `PERMISSION_PROFILE` | `minimum-dynamic` | Palette role policy model: `core`, `minimum-dynamic`, or `minimum-static`. Existing configs derive a minimum profile from `PLACEMENT_MODE` when omitted. |
| `PLACEMENT_MODE` | `dynamic` | Set to `dynamic` or `static` to select the applicable EC2 permission set. |
| `TARGET_ACCOUNT_ID` | Unset | Target AWS account for optional mode-specific cross-account validation. |
| `CONFIG_FILE` | `validate-iam.conf` beside the script | Path to an alternative configuration file. |

To change role names, placement mode, or cross-account validation, edit the corresponding values in `validate-iam.conf`. For example:

```bash
PERMISSION_PROFILE="minimum-static"
PLACEMENT_MODE="static"
DEPLOYER_ROLE_NAME="CustomDeployerRole"
TARGET_ACCOUNT_ID="123456789012"
```

Then run the validator:

```bash
./validate-iam.sh
```

When `TARGET_ACCOUNT_ID` is set, STS mode tests the target deployer role. Pod Identity mode tests the target deployer and Hubble roles. Secret mode skips cross-account role assumption.

To use a configuration file stored elsewhere:

```bash
CONFIG_FILE=/secure/path/production.conf ./validate-iam.sh
```

Configuration files are sourced as shell code. Only use files you trust and keep environment-specific files out of version control.

## Pre-deployment and runtime checks

Most Pod Identity validation does not require the VerteX application to be
installed. Before deployment, the script can verify:

- The Palette, Hubble, and Identity roles exist.
- Each role trusts `pods.eks.amazonaws.com` for `sts:AssumeRole` and
  `sts:TagSession`.
- The roles have their documented permission sets.
- The Pod Identity Agent add-on is active.
- Hubble and Identity service-account associations exist.
- `kube-system/palette-global-config` contains the management cluster name.

Section 11 is an optional runtime check. It inspects the `spectro-hubble` and
`palette-identity` pods only when those workloads exist. If the application
has not been installed, no matching pod exists, or the pods cannot be queried,
the script reports `WARN` and skips the check. Once a matching pod exists,
missing `AWS_CONTAINER_CREDENTIALS_FULL_URI` or
`AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE` is a failure because the workload was
not mutated for Pod Identity.

The AWS cluster checks use `CLUSTER_NAME`, but Kubernetes checks use the
current kubeconfig context. The script does not switch contexts. Verify it
before running:

```bash
kubectl config current-context
kubectl cluster-info
```

The current context must point to the same management cluster configured in
`CLUSTER_NAME`.

## Bundled policy examples

The JSON files in `policies/` are reference policies collected while configuring this validator; the script does not load or apply them automatically.

| File | Purpose |
| --- | --- |
| `policies/deployer-trust-policy.json` | EKS Pod Identity trust policy for the deployer role. |
| `policies/palette-identity-trust-policy.json` | EKS Pod Identity trust policy for the Palette identity role. |
| `policies/palette-identity-eks-policy.json` | EKS, EC2, and IAM permissions for the Palette identity role. |
| `policies/trust-policy.json` | Generic EKS Pod Identity trust policy example. |
| `policies/capa-passrole-policy.template.json` | Reusable CAPA role permissions template rendered with the configured partition and account. |
| `policies/sts-tag-session-policy.json` | `sts:TagSession` permission example. |

Review every policy before using it. Some examples contain a specific account ID and the `aws-us-gov` partition and must be adapted to the target account, partition, role names, and least-privilege requirements.

The CAPA policy is intentionally account-neutral. Its `${CAPA_ROLE_PATTERN}` placeholder is not an AWS IAM policy variable and must be rendered before the policy is attached:

```bash
./render-capa-policy.sh
```

The renderer reads `PARTITION`, `ACCOUNT_ID`, and `AWS_PROFILE` from `validate-iam.conf`. If `ACCOUNT_ID` is empty, it resolves the account from the configured AWS credentials. To render and attach it directly:

```bash
source ./validate-iam.conf
export AWS_PROFILE
aws iam put-role-policy \
  --role-name "$DEPLOYER_ROLE_NAME" \
  --policy-name PaletteCAPAPassRole \
  --policy-document "$(./render-capa-policy.sh)" \
  --profile "$AWS_PROFILE"
```

## Understanding failures

- `implicitDeny` usually means no applicable allow statement grants the simulated action.
- `explicitDeny` means an applicable policy explicitly denies the action.
- `error` can indicate that the caller cannot run `iam:SimulatePrincipalPolicy`, that a role does not exist, or that AWS credentials/configuration are invalid.
- Unexpected add-on failures can indicate that `PERMISSION_PROFILE` does not match the profile used by `eks-deploy`. Minimum profiles intentionally test fewer Palette-role add-on actions than `core`.
- An `sts:AssumeRole` failure can come from either side of the relationship: the caller needs permission to assume the role, and the target role must trust the caller.
- Missing Pod Identity environment variables usually means the association or EKS Pod Identity Agent is absent, unhealthy, or did not mutate the pod. Restarting the workload may be necessary after correcting the association.
- If the IAM checks pass but deployment still fails, inspect service control policies, permission boundaries, session policies, resource policies, and conditions. IAM policy simulation does not reproduce every part of a live authorization decision.

For example, if the Palette role fails `iam:PassRole` on `*`, the output
provides a command that attaches the bundled Pod Identity management policy as
an inline role policy. Review the policy and command before running it. If the
result remains denied afterward, inspect the role's permissions boundary and
AWS Organizations service control policies.

CAPA and OIDC permission simulations use the configured `ACCOUNT_ID` in their resource ARNs. This allows least-privilege policies scoped to the current account to match correctly; the validator does not require cross-account wildcards for these resources.

For live Kubernetes checks, ensure the active `kubectl` context points to the same management cluster configured in `CLUSTER_NAME`:

```bash
kubectl config current-context
kubectl get configmap palette-global-config -n kube-system
kubectl get pods -n hubble-system
```

## Scope and safety

Run the validator with a dedicated read-only diagnostic identity plus only the additional simulation and role-assumption permissions it requires. Review the output before sharing it: account IDs, role ARNs, cluster names, OIDC issuers, and Pod Identity associations may be displayed.

## References

- [Add an AWS account to Palette](https://docs.spectrocloud.com/clusters/public-cloud/aws/add-aws-accounts/)
- [Spectro Cloud required IAM policies](https://docs.spectrocloud.com/clusters/public-cloud/aws/required-iam-policies/)
- [Spectro Cloud minimum permissions policies](https://docs.spectrocloud.com/clusters/public-cloud/aws/required-iam-policies/minimum-permissions-policies/)
- [Spectro Cloud core IAM policies](https://docs.spectrocloud.com/clusters/public-cloud/aws/required-iam-policies/core-iam-policies/)
- [Spectro Cloud additional IAM policies](https://docs.spectrocloud.com/clusters/public-cloud/aws/required-iam-policies/additional-iam-policies-specific-use-cases/)
- [Amazon EKS Pod Identity](https://docs.aws.amazon.com/eks/latest/userguide/pod-identities.html)
- [IAM policy simulation](https://docs.aws.amazon.com/IAM/latest/UserGuide/access_policies_testing-policies.html)
