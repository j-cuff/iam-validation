# validate-iam

`validate-iam.sh` checks the AWS IAM and EKS configuration used to deploy
Spectro Cloud Palette VerteX on EKS. It supports static IAM user credentials,
STS role assumption, and EKS Pod Identity (same-account and cross-account)
across the `aws`, `aws-us-gov`, `aws-iso`, and `aws-iso-b` partitions.

The validator is diagnostic. It reads AWS and Kubernetes configuration,
simulates IAM policy decisions, and, in STS mode, requests short-lived role
sessions. It does not create roles, attach policies, install add-ons, or
modify the cluster. Failed checks print a suggested `FIX`, but the script never
runs that remediation automatically.

`setup-iam.sh` is its companion: it creates the roles, policies, and Pod
Identity associations for STS or Pod Identity from the same configuration, so
that the validator passes. See [Setting up IAM](#setting-up-iam-with-setup-iamsh).

The IAM checks follow the Spectro Cloud documentation as of **2026-11-20**,
including the November 3, 2026 update to the Minimum EKS Dynamic policy. See
[Keeping up with the Spectro Cloud docs](#keeping-up-with-the-spectro-cloud-docs)
to re-check after the docs change.

## Requirements

- Bash (3.2 or later; the macOS system Bash works)
- AWS CLI with a configured profile and region
- `jq`
- `kubectl` and access to the management cluster for the optional Kubernetes
  checks in Pod Identity mode
- Permission for the active AWS identity to inspect the configured resources
  and run `iam:SimulatePrincipalPolicy`
- Permission to call `sts:AssumeRole` when using STS mode
- For `setup-iam.sh`: permission to create and update IAM roles and policies
  (and, depending on the options, EKS Pod Identity associations and add-ons,
  CloudFormation stacks, and ConfigMaps in `kube-system`)
- Python 3, only to run the offline tests in `tests/`

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

## Setting up IAM with setup-iam.sh

`setup-iam.sh` creates or updates everything the validator checks, using the
policies published in the Spectro Cloud docs (`policies/spectro-docs`). It
reads the same `validate-iam.conf`, accepts the same mode argument, and prints a
plan unless you pass `--apply`:

```bash
./setup-iam.sh pod-identity            # show the plan
./setup-iam.sh pod-identity --apply    # make the changes
./validate-iam.sh pod-identity         # confirm
```

What it sets up:

| Mode | Roles and policies | Also |
| --- | --- | --- |
| `sts` | `DEPLOYER_ROLE_NAME`, trusting `STS_TRUSTED_ACCOUNT_ID` with the `STS_EXTERNAL_ID` condition, with the `PERMISSION_PROFILE` policies attached. With `TARGET_ACCOUNT_ID` and `TARGET_AWS_PROFILE`, the same role in the target account. | |
| `pod-identity` | The Palette role (trusting `pods.eks.amazonaws.com`, with the profile policies and the docs' Pod Identity supplement), the Hubble role, and the identity role, each with the docs' policy. | Pod Identity associations for `hubble-system/spectro-hubble` and `palette-identity/palette-identity` when `CLUSTER_NAME` is set. |
| `pod-identity` with `TARGET_ACCOUNT_ID` | The docs' cross-account model: identity and Hubble local roles in this account; Palette and Hubble target roles in the target account (via `TARGET_AWS_PROFILE`), with the `sts:ExternalId` values computed from the region, account, and `CLUSTER_NAME`. | The Hubble association uses the Hubble target role. |

Options in the configuration file:

- `CFN_STACK_MODE` — `palette` (default) attaches the docs' CloudFormation
  stack permissions so Palette creates the CAPA roles (Option 1; the core
  policies already include them). `manual` creates the
  `cluster-api-provider-aws-sigs-k8s-io` stack now from the docs template
  (Option 2); then set `manageCloudFormationStackManually.enabled: true` in your
  cluster profiles. `none` does neither.
- `SETUP_CLUSTER_PREREQS=true` also installs the `eks-pod-identity-agent`
  add-on and creates `kube-system/palette-global-config`. The ConfigMap step
  runs only if the current kubectl context's API server is `CLUSTER_NAME`'s
  endpoint, and it never overwrites a different existing value.
- `POLICY_NAME_SUFFIX` (defaults to `ROLE_ID_SUFFIX`) is appended to the
  managed policy names, so several environments can share an account.

How it changes things:

- **Plan first.** Without `--apply` it reads the account and lists every
  change as `[PLAN]`; nothing is modified.
- **Idempotent.** Re-running applies only what is missing or out of date, and
  reports `Nothing to change` when everything matches.
- **Additive.** It adds missing trust statements and keeps the others (a
  statement with the same `Sid` is replaced), attaches policies, and never
  deletes or detaches roles or policies.
- **Managed policies.** The Palette role's policies are customer managed
  policies named after the docs (`PaletteMinimumEKSDynamicPolicy`,
  `PaletteControllerPolicy`, …) and tagged `ManagedBy=iam-validation-setup`.
  It updates only policies with that tag; a same-named policy without it is
  attached as-is, with a warning listing the actions it lacks. When one of its
  policies already has five versions, it deletes the oldest non-default one
  before adding the new version (AWS keeps at most five).
- **Inline policies.** The Hubble and identity roles get inline policies
  (`PaletteHubblePermissions`, `PaletteIdentityPermissions`,
  `PaletteHubbleCrossAccount`).
- **Partitions.** Outside `aws`, it rewrites the docs' hardcoded `arn:aws:`
  ARNs (in the minimum EKS policies, PaletteControllersEKSPolicy, and the
  CloudFormation template) to the configured partition.
- **Retries.** IAM changes take a few seconds to propagate, so a trust policy
  that names a just-created role can be rejected briefly. Such errors are
  retried (`SETUP_RETRY_ATTEMPTS`, default 10, every `SETUP_RETRY_DELAY`
  seconds, default 6). Any other error stops the run; re-running resumes.

The summary ends with the role ARN to enter in Palette's **Add AWS Account**
wizard.

`secret` mode has no roles to create: attach the docs policies in
`policies/spectro-docs` to the IAM user yourself.

## Configuration

`validate-iam.conf.example` is executable shell syntax and is sourced by every
script in this project. Only use a configuration file you trust.

`AWS_PROFILE` is required. Every other setting has a default, so configuration
files written for earlier versions of the script keep working.

| Variable | Example/default | Purpose |
| --- | --- | --- |
| `AWS_PROFILE` | `your-profile` | Required. AWS CLI profile for the account that holds the Palette roles. Used for all local-account AWS calls and exported as `AWS_PROFILE`. |
| `PARTITION` | `aws` | One of `aws`, `aws-us-gov`, `aws-iso`, or `aws-iso-b`. Used to construct resource ARNs. |
| `AUTH_MODE` | `pod-identity` | One of `secret`, `sts`, or `pod-identity`. A positional argument overrides this value for one run. |
| `CLUSTER_NAME` | `your-eks-cluster` | EKS management cluster used for AWS cluster checks. Set it to an empty string to skip those checks and the `palette-global-config` check. |
| `ACCOUNT_ID` | Empty | Account containing the local roles. When empty, it is resolved with `sts:GetCallerIdentity`. |
| `ROLE_ID_SUFFIX` | Empty | Optional suffix used by the example configuration to derive all three default role names. |
| `DEPLOYER_ROLE_NAME` | `SpectroCloudPaletteRole` | Palette/cloud-account role validated in STS and same-account Pod Identity modes. |
| `HUBBLE_ROLE_NAME` | `SpectroCloudHubbleRole` | Hubble role (the Hubble local role in cross-account mode). |
| `IDENTITY_ROLE_NAME` | `SpectroCloudIdentityRole` | Palette identity role (the identity local role in cross-account mode). |
| `PERMISSION_PROFILE` | `minimum-dynamic` | One of `core`, `minimum-dynamic`, or `minimum-static`. Selects which documented policy the Palette-role checks follow. |
| `PLACEMENT_MODE` | `dynamic` | One of `dynamic` or `static`. Controls the placement-specific EC2 actions checked. |
| `STS_TRUSTED_ACCOUNT_ID` | Empty | STS mode. The AWS account ID from the Palette **Add AWS Account** wizard: the account configured for STS on your Palette/VerteX instance. Required by `setup-iam.sh`; lets the validator check the trust policy directly. |
| `STS_EXTERNAL_ID` | Empty | STS mode. The External ID from the Palette **Add AWS Account** wizard. The documented STS role requires it. |
| `STS_CALLER_PROFILE` | Empty | STS mode. A profile with credentials in `STS_TRUSTED_ACCOUNT_ID`, used for the validator's live assume-role test. |
| `STS_SESSION_TAGS` | `false` | STS mode. `true` also requests session tags, which needs `sts:TagSession` in the trust policy. |
| `TARGET_ACCOUNT_ID` | Empty | Enables cross-account checks when set. |
| `TARGET_DEPLOYER_ROLE_NAME` | `DEPLOYER_ROLE_NAME` | Palette role name in the target account, for example `SpectroCloudPaletteTargetRole`. |
| `TARGET_HUBBLE_ROLE_NAME` | `HUBBLE_ROLE_NAME` | Hubble target role name, for example `SpectroCloudHubbleTargetRole`. |
| `TARGET_AWS_PROFILE` | Empty | A profile for the target account. `setup-iam.sh` creates the target roles with it; the validator uses it to check them and skips those checks with a warning when it is empty. |
| `CFN_STACK_MODE` | `palette` | `setup-iam.sh`. `palette`, `manual`, or `none`; see [Setting up IAM](#setting-up-iam-with-setup-iamsh). |
| `SETUP_CLUSTER_PREREQS` | `false` | `setup-iam.sh`. `true` also installs the Pod Identity agent add-on and the `palette-global-config` ConfigMap. |
| `POLICY_NAME_SUFFIX` | `ROLE_ID_SUFFIX` | `setup-iam.sh`. Suffix for the managed policy names. |
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

The region is resolved the same way the AWS CLI resolves it: `AWS_REGION`,
then `AWS_DEFAULT_REGION`, then the profile's `region` setting.

## Authentication modes

The mode determines which principal is simulated and which specialized checks
run.

| Mode | Deployment principal | Additional behavior |
| --- | --- | --- |
| `secret` | The IAM user returned by the configured AWS profile | Rejects assumed-role, federated, and root caller ARNs. Skips role assumption and all Pod Identity checks. |
| `sts` | The role named by `DEPLOYER_ROLE_NAME` | Checks that the trust policy trusts `STS_TRUSTED_ACCOUNT_ID` with the External ID, and performs a real 15-minute `sts:AssumeRole` request from that account, passing `STS_EXTERNAL_ID` and, if enabled, a `PaletteValidation=true` session tag. |
| `pod-identity` | The Palette role (local, or in the target account for cross-account), plus the Hubble and identity roles | Validates Pod Identity trust, role permissions, add-on state, associations, Kubernetes configuration, and runtime environment injection. |

For `secret` mode, `AWS_PROFILE` must use the same IAM user's access key that
Palette will store. A profile that assumes a role does not validate the static
credential principal and is rejected.

For `sts` mode, `AWS_PROFILE` is the account that holds the role. Palette
assumes the role from a different account: the one configured for STS on your
Palette or VerteX instance, shown in the **Add AWS Account** wizard. Set
`STS_TRUSTED_ACCOUNT_ID` and `STS_EXTERNAL_ID` to the wizard's values, and the
validator reads the trust policy and checks both, which needs no credentials in
that account. To also test a real assume-role request, set `STS_CALLER_PROFILE`
to a profile in that account (self-hosted Palette/VerteX only; Palette SaaS
users do not have one). If `STS_TRUSTED_ACCOUNT_ID` is empty, the validator
attempts the assume-role request with `AWS_PROFILE`, as earlier versions did.

## Permission and placement profiles

`PERMISSION_PROFILE` selects the documented policy that the Palette-role checks
follow:

| Profile | Docs policy | Checks added beyond the common set |
| --- | --- | --- |
| `minimum-dynamic` | Minimum EKS Dynamic Permissions (updated November 3, 2026) | Dynamic EC2 actions; IAM actions on `*-iam-service-role` and `ng-role_*` roles including `iam:PassRole`; `iam:GetPolicy` on AWS managed policies; EKS service-linked role create/read; `ssm:GetParameter` for EKS-optimized AMIs; Auto Scaling group management and instance refresh. |
| `minimum-static` | Minimum EKS Static Permissions (February 21, 2026) | `ec2:DeleteTags`. |
| `core` | Core IAM policies plus PaletteControllersEKSPolicy | The same additions as `minimum-dynamic` except `iam:PassRole` on the EKS cluster and node group roles, which the core policies do not grant. |

Every profile also checks the EC2 actions common to both minimum policies
(including `ec2:DescribeAddresses` and `ec2:DescribeTags`), the core EKS
actions, OIDC-provider management, CAPA-role access, and
`autoscaling:DescribeAutoScalingGroups`. `PLACEMENT_MODE` chooses the dynamic
or static EC2 set.

Where a documented statement is scoped to specific resources, the script
simulates against a sample ARN that matches the documented pattern (for
example `arn:<partition>:eks:<region>:<account>:cluster/palette-validation-sample`).
A literal `*` resource does not match a scoped statement, so simulating against
`*` would report a false denial.

In Pod Identity mode, `PERMISSION_PROFILE` also selects the Palette role's EKS
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
resolve the account and region, and print the selected account, partition,
region, cluster, placement mode, permission profile, authentication mode, and
caller. The numbered validation sections are:

1. **Credential baseline** — verifies `sts:GetCallerIdentity` with the active
   credentials.
2. **EKS deployment permissions** — confirms the Palette role exists and
   simulates the documented policy for the selected profile on the deployment
   principal. If the role is missing, the script reports it once and skips the
   simulations. EKS add-on permissions are included only in Pod Identity mode.
3. **Pod Identity role trust** — in Pod Identity mode, confirms that the roles
   exist and have an `Allow` trust statement for `pods.eks.amazonaws.com` with
   `sts:AssumeRole` and `sts:TagSession`.
4. **Pod Identity role permissions** — in Pod Identity mode, simulates Pod
   Identity management and `iam:PassRole` for the Palette role; IAM, EC2, EKS,
   and KMS read permissions for Hubble (the Hubble target role in
   cross-account mode); and Pod Identity management, EC2, `GetRole`, and
   `PassRole` permissions for the identity role.
5. **STS validation** — in STS mode, checks that the deployer role's trust
   policy trusts `STS_TRUSTED_ACCOUNT_ID` with the configured External ID (and
   `sts:TagSession` if `STS_SESSION_TAGS=true`), then attempts the assume-role
   request when credentials for that account are available.
6. **EKS cluster checks** — when `CLUSTER_NAME` is set, checks that the cluster
   is active and inspects its OIDC issuer. The IAM OIDC provider ARN is built
   from the issuer, and a missing provider is a warning because EKS Pod
   Identity does not need it. In Pod Identity mode it also checks Kubernetes
   1.24 or later, the `eks-pod-identity-agent` add-on, and the Hubble and
   identity service-account associations, including whether each is bound to
   the configured role.
7. **Partition validation** — checks the applicable principal or role ARNs
   against `PARTITION`. GovCloud additionally checks that the region is a
   GovCloud region.
8. **CAPA roles and CloudFormation** — looks for the four roles that the
   documented CloudFormation template creates
   (`control-plane`, `controllers`, `eks-controlplane`, and `nodes`
   `.cluster-api-provider-aws.sigs.k8s.io`) and reports the optional
   `eks-nodegroup` and `eks-fargate` roles for information. It also simulates
   the documented Option 1 CloudFormation stack permissions. Missing roles fail
   only when Palette also lacks those permissions, because then neither Palette
   nor an existing manual stack provides them.
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
namespace and service-account pairs and warns when an association is bound to
a role other than the configured one. The EKS list call does not return role
ARNs, so each association is described individually. In cross-account mode,
the Hubble association must also use the Hubble target role.

```text
hubble-system/spectro-hubble     → HUBBLE_ROLE_NAME
palette-identity/palette-identity → IDENTITY_ROLE_NAME
```

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
- `sts` mode runs the same STS checks against `TARGET_DEPLOYER_ROLE_NAME` in the
  target account: the trust policy check (with `TARGET_AWS_PROFILE`) and the
  live assume-role request (with credentials in `STS_TRUSTED_ACCOUNT_ID`).
- `pod-identity` mode follows the documented cross-account model. The Palette
  role and the Hubble target role live in the target account; only the
  identity and Hubble local roles live in the management account. The script:
  - checks the local roles' Pod Identity trust and permissions;
  - simulates `iam:GetRole`, `iam:PassRole`, `sts:AssumeRole`, and
    `sts:TagSession` for the identity local role on the target Palette role and
    on itself (the docs' policy lists its own ARN), and for the Hubble local
    role on the Hubble target role.
  - With `TARGET_AWS_PROFILE` set, it also simulates the documented Palette and
    Hubble policies on the target roles, checks the target CAPA roles, and reads
    the target trust policies. Those must allow the local roles to call
    `sts:AssumeRole` and `sts:TagSession`, with these `sts:ExternalId` values:

    ```text
    Palette target: <region>/<mgmt-account>/<cluster>/palette-identity/palette-identity
                    <region>/<mgmt-account>/<cluster>/*/palette-manager
    Hubble target:  <region>/<mgmt-account>/<cluster>/hubble-system/spectro-hubble
    ```

The docs' Hubble target trust policy names the local role
`role/spectro-hubble-identity`, while the docs' role table suggests
`SpectroCloudHubbleLocalRole`. The trust policy must name whatever role
`HUBBLE_ROLE_NAME` is; the script reports a failure if it does not.

## Using it after `eks-deploy up`

`eks-deploy` is a separate companion project (not part of this repository) that
creates the IAM resources; `validate-iam` independently checks them. Map the
configuration values as follows:

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

## Policy renderers

The renderers fill a policy template with the partition and account from the
selected configuration. When `ACCOUNT_ID` is empty, they resolve the account
with STS. They print the policy and do not attach or modify anything.

| Script | Template | Output |
| --- | --- | --- |
| `render-capa-policy.sh` | `policies/capa-passrole-policy.template.json` | CAPA `GetRole`, `PassRole`, and `ListAttachedRolePolicies` scoped to `*.cluster-api-provider-aws.sigs.k8s.io` roles. |
| `render-identity-policy.sh` | `policies/palette-identity-eks-policy.template.json` | Same-account identity-role policy, with `GetRole` and `PassRole` scoped to `DEPLOYER_ROLE_NAME`. |

```bash
./render-capa-policy.sh
CONFIG_FILE=/secure/path/production.conf ./render-identity-policy.sh
```

To attach a rendered policy, first review it, then run an explicit AWS CLI
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

## Bundled policy examples

Files under `policies/` are reference material and possible remediation input.
The validator does not automatically load or apply them.

| File | Purpose |
| --- | --- |
| `spectro-docs/` | The IAM policies and CloudFormation template published in the Spectro Cloud docs, with placeholders as published. `setup-iam.sh` applies them; the tests check the validator against them. `SOURCE.md` records where each came from. |
| `capa-passrole-policy.template.json` | Account-neutral CAPA `GetRole`, `PassRole`, and `ListAttachedRolePolicies` template consumed by `render-capa-policy.sh`. |
| `deployer-trust-policy.json` | EKS Pod Identity trust example for the deployer role. |
| `deployerv2-passrole.json` | The docs' minimum-policy Pod Identity supplement for the Palette role: Pod Identity associations, supported add-ons, and `PassRole`. |
| `palette-identity-eks-policy.template.json` | Same-account identity-role template consumed by `render-identity-policy.sh`. |
| `palette-identity-trust-policy.json` | EKS Pod Identity trust example for the identity role. |
| `sts-tag-session-policy.json` | Broad `sts:TagSession` permissions example. |
| `trust-policy.json` | Generic EKS Pod Identity trust example. |

Review and scope every policy before using it; several examples use wildcard
resources.

## Tests

`tests/run_tests.py` runs the scripts offline against mock `aws` and
`kubectl` commands (in `tests/mock`) that keep a fake AWS account in a JSON
file. Validator scenarios give the fake roles the exact policies published in
the Spectro Cloud docs (`policies/spectro-docs`) and check the exit status and
the number of failed checks. Setup scenarios run `setup-iam.sh` against an
empty account, then the validator against the result (expecting no failures),
then `setup-iam.sh` again (expecting no changes). Together they cover every
mode and permission profile, GovCloud, cross-account Pod Identity, CAPA roles
and CloudFormation, existing trust statements and policies, and older
configuration files.

Coverage checks then confirm that the validator simulated every action in the
documented policies, against a resource the documented statement covers.

```bash
python3 tests/run_tests.py          # all scenarios
python3 tests/run_tests.py -v sts   # scenarios whose title contains "sts", with full output on failure
```

The mock evaluates `Allow` and `Deny` statements with wildcards but ignores
statements that have conditions (except `sts:ExternalId` in trust policies),
and it applies IAM changes instantly. A passing run therefore shows the scripts
match the documented policies, not that a live AWS account is configured
correctly.

## Keeping up with the Spectro Cloud docs

When Spectro Cloud updates its IAM documentation:

1. Refresh `policies/spectro-docs` from the docs source on GitHub:

   ```bash
   python3 tests/sync_docs_fixtures.py
   ```

   It prints the actions added to or removed from each policy and records the
   docs' "Last Update" stamps in `policies/spectro-docs/SOURCE.md`.
2. Run `python3 tests/run_tests.py`. A coverage failure names a documented
   permission that `validate-iam.sh` does not check yet; a scenario failure
   means a check now conflicts with the docs.
3. Update `validate-iam.sh`, `DOCS_SYNC_DATE` in it and in `setup-iam.sh`, and
   this README. Running `setup-iam.sh` then brings existing environments up to
   the new policies.

## Troubleshooting

- `implicitDeny` means no applicable allow statement grants the simulated
  action.
- `explicitDeny` means an applicable policy explicitly denies the action.
- A simulation error usually means the current caller lacks
  `iam:SimulatePrincipalPolicy`, the simulated role does not exist, or an ARN
  is invalid. The first line of the AWS error is printed with the failure.
- In GovCloud and the isolated partitions, the OIDC provider checks fail if you
  copied the minimum EKS policies verbatim: their
  `IAMOpenIDConnectProviderPermissions` statement uses
  `arn:aws:iam::*:oidc-provider/*`. Change it to `arn:*:iam::*:oidc-provider/*`.
- `eks:CreateCluster` has no resource-level permissions, so IAM allows it only
  through a statement with `"Resource": "*"`, and the validator checks it
  against `*`. The minimum EKS policies grant it that way. The docs' core
  PaletteControllersEKSPolicy grants it only on `arn:*:eks:*:*:cluster/*`,
  which never allows it, so with the core policies this check fails until you
  add a statement allowing `eks:CreateCluster` on `*`.
- A failed STS check can originate on either side: the caller must be the
  account the role trusts, the external ID must match, and session tags need
  `sts:TagSession` in the trust policy.
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
- [Spectro Cloud docs source (librarium)](https://github.com/spectrocloud/librarium)
- [Amazon EKS Pod Identity](https://docs.aws.amazon.com/eks/latest/userguide/pod-identities.html)
- [IAM policy simulation](https://docs.aws.amazon.com/IAM/latest/UserGuide/access_policies_testing-policies.html)
