#!/usr/bin/env bash
# =============================================================================
# validate-iam.sh
#
# Validates the AWS IAM and EKS configuration used to deploy Spectro Cloud
# Palette VerteX on EKS with static secrets, STS, or EKS Pod Identity. Supports
# commercial (aws), GovCloud (aws-us-gov), and isolated partitions.
#
# The IAM checks follow these Spectro Cloud documentation pages (see
# DOCS_SYNC_DATE and tests/fixtures/docs/SOURCE.md):
#   - Minimum EKS Dynamic permissions   (docs "Last Update": November 3, 2026)
#   - Minimum EKS Static permissions    (docs "Last Update": February 21, 2026)
#   - Core IAM policies and PaletteControllersEKSPolicy
#   - CloudFormation stack permissions  (Option 1, Palette-managed stack)
#   - EKS Pod Identity prerequisites    (Palette, Hubble, and identity roles,
#                                        same-account and cross-account)
#
# Usage:
#   cp validate-iam.conf.example validate-iam.conf
#   # Edit validate-iam.conf for your environment
#   ./validate-iam.sh [secret|sts|pod-identity]
#
# To use a config stored elsewhere:
#   CONFIG_FILE=/path/to/validate-iam.conf ./validate-iam.sh
# =============================================================================

set -euo pipefail

DOCS_SYNC_DATE="2026-11-20"

# ─── Load configuration ─────────────────────────────────────────────────────
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
CONFIG_FILE="${CONFIG_FILE:-${SCRIPT_DIR}/validate-iam.conf}"

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "ERROR: Configuration file not found: $CONFIG_FILE" >&2
  echo "Create one with: cp '${SCRIPT_DIR}/validate-iam.conf.example' '${SCRIPT_DIR}/validate-iam.conf'" >&2
  exit 1
fi

# shellcheck source=/dev/null
source "$CONFIG_FILE"

if [[ "$#" -gt 1 ]]; then
  echo "Usage: $0 [secret|sts|pod-identity]" >&2
  exit 2
fi

if [[ -z "${AWS_PROFILE:-}" ]]; then
  echo "ERROR: AWS_PROFILE is not set in $CONFIG_FILE" >&2
  exit 1
fi
export AWS_PROFILE

# Optional settings. The defaults keep configuration files written for earlier
# versions of this script working under `set -u`.
AUTH_MODE="${1:-${AUTH_MODE:-}}"
PARTITION="${PARTITION:-aws}"
CLUSTER_NAME="${CLUSTER_NAME:-}"
ACCOUNT_ID="${ACCOUNT_ID:-}"
DEPLOYER_ROLE_NAME="${DEPLOYER_ROLE_NAME:-SpectroCloudPaletteRole}"
HUBBLE_ROLE_NAME="${HUBBLE_ROLE_NAME:-SpectroCloudHubbleRole}"
IDENTITY_ROLE_NAME="${IDENTITY_ROLE_NAME:-SpectroCloudIdentityRole}"
PLACEMENT_MODE="${PLACEMENT_MODE:-dynamic}"
# Existing configurations predate PERMISSION_PROFILE. Derive the matching
# minimum profile so they retain their previous dynamic/static intent.
PERMISSION_PROFILE="${PERMISSION_PROFILE:-minimum-${PLACEMENT_MODE}}"
TARGET_ACCOUNT_ID="${TARGET_ACCOUNT_ID:-}"
TARGET_DEPLOYER_ROLE_NAME="${TARGET_DEPLOYER_ROLE_NAME:-$DEPLOYER_ROLE_NAME}"
TARGET_HUBBLE_ROLE_NAME="${TARGET_HUBBLE_ROLE_NAME:-$HUBBLE_ROLE_NAME}"
TARGET_AWS_PROFILE="${TARGET_AWS_PROFILE:-}"
STS_EXTERNAL_ID="${STS_EXTERNAL_ID:-}"
STS_SESSION_TAGS="${STS_SESSION_TAGS:-false}"

# ─── Colour helpers ──────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

pass()  { echo -e "  ${GREEN}[PASS]${RESET} $*"; }
fail()  {
  local message="$1"
  local remediation="${2:-}"
  echo -e "  ${RED}[FAIL]${RESET} $message"
  if [[ -n "$remediation" ]]; then
    echo -e "         ${YELLOW}FIX:${RESET} $remediation"
  fi
  FAILURES=$((FAILURES+1))
}
warn()  { echo -e "  ${YELLOW}[WARN]${RESET} $*"; }
info()  { echo -e "  ${CYAN}[INFO]${RESET} $*"; }
header(){ echo -e "\n${BOLD}${CYAN}══════════════════════════════════════════${RESET}"; \
          echo -e "${BOLD}${CYAN}  $*${RESET}"; \
          echo -e "${BOLD}${CYAN}══════════════════════════════════════════${RESET}"; }

FAILURES=0

case "$AUTH_MODE" in
  secret|sts|pod-identity) ;;
  *)
    echo -e "${RED}ERROR: Unknown AUTH_MODE '$AUTH_MODE'. Valid: secret | sts | pod-identity${RESET}"
    exit 1
    ;;
esac

case "$PLACEMENT_MODE" in
  dynamic|static) ;;
  *)
    echo -e "${RED}ERROR: Unknown PLACEMENT_MODE '$PLACEMENT_MODE'. Valid: dynamic | static${RESET}"
    exit 1
    ;;
esac

case "$PERMISSION_PROFILE" in
  core|minimum-dynamic|minimum-static) ;;
  *)
    echo -e "${RED}ERROR: Unknown PERMISSION_PROFILE '$PERMISSION_PROFILE'. Valid: core | minimum-dynamic | minimum-static${RESET}"
    exit 1
    ;;
esac

if [[ "$PERMISSION_PROFILE" == "minimum-dynamic" && "$PLACEMENT_MODE" != "dynamic" ]] ||
   [[ "$PERMISSION_PROFILE" == "minimum-static" && "$PLACEMENT_MODE" != "static" ]]; then
  echo -e "${RED}ERROR: PERMISSION_PROFILE '$PERMISSION_PROFILE' conflicts with PLACEMENT_MODE '$PLACEMENT_MODE'.${RESET}"
  exit 1
fi

case "$STS_SESSION_TAGS" in
  true|false) ;;
  *)
    echo -e "${RED}ERROR: STS_SESSION_TAGS must be 'true' or 'false', not '$STS_SESSION_TAGS'.${RESET}"
    exit 1
    ;;
esac

# Derive the partition-specific ARN prefix and a representative region used
# only to build sample resource ARNs for policy simulation.
case "$PARTITION" in
  aws)         ARN_PREFIX="arn:aws";         DEFAULT_REGION="us-east-1"      ;;
  aws-us-gov)  ARN_PREFIX="arn:aws-us-gov";  DEFAULT_REGION="us-gov-west-1"  ;;
  aws-iso)     ARN_PREFIX="arn:aws-iso";     DEFAULT_REGION="us-iso-east-1"  ;;
  aws-iso-b)   ARN_PREFIX="arn:aws-iso-b";   DEFAULT_REGION="us-isob-east-1" ;;
  *)
    echo -e "${RED}ERROR: Unknown partition '$PARTITION'. Valid: aws | aws-us-gov | aws-iso | aws-iso-b${RESET}"
    exit 1
    ;;
esac

ERR_FILE=$(mktemp "${TMPDIR:-/tmp}/validate-iam.XXXXXX")
trap 'rm -f "$ERR_FILE"' EXIT

# First line of the last captured AWS CLI error, for concise diagnostics.
last_error() {
  local line
  line=$(grep -v '^[[:space:]]*$' "$ERR_FILE" 2>/dev/null | head -1 || true)
  echo "${line:-no error output}"
}

# Run the AWS CLI with a specific profile.
aws_as() {
  local profile="$1"; shift
  AWS_PROFILE="$profile" aws "$@"
}

# ─── Pre-flight checks ───────────────────────────────────────────────────────
header "Pre-flight Checks"

# Require AWS CLI
if ! command -v aws &>/dev/null; then
  echo -e "${RED}ERROR: aws CLI not found. Install it first.${RESET}"; exit 1
fi
pass "aws CLI found: $(aws --version 2>&1 | head -1)"

# Require jq
if ! command -v jq &>/dev/null; then
  echo -e "${RED}ERROR: jq not found. Install it first.${RESET}"; exit 1
fi
pass "jq found"

# Resolve account ID if not provided
if [[ -z "$ACCOUNT_ID" ]]; then
  ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null || true)
  if [[ -z "$ACCOUNT_ID" ]]; then
    fail "Cannot resolve AWS Account ID. Check credentials / AWS_PROFILE." \
      "Run 'aws sts get-caller-identity --profile $AWS_PROFILE'. If it fails, correct AWS_PROFILE, authenticate the profile, and verify its configured region."
    exit 1
  fi
fi

# Resolve the region the same way the AWS CLI does: AWS_REGION, then
# AWS_DEFAULT_REGION, then the profile. `aws configure get region` alone
# ignores the environment variables.
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-}}"
if [[ -z "$REGION" ]]; then
  REGION=$(aws configure get region 2>/dev/null || true)
fi
SAMPLE_REGION="${REGION:-$DEFAULT_REGION}"

info "Account ID  : $ACCOUNT_ID"
info "Partition   : $PARTITION  (ARN prefix: $ARN_PREFIX)"
info "Region      : ${REGION:-<not set>}"
info "Cluster     : ${CLUSTER_NAME:-<not set — EKS checks will be skipped>}"
info "Placement   : $PLACEMENT_MODE"
info "Permissions : $PERMISSION_PROFILE"
info "Auth mode   : $AUTH_MODE"
info "IAM checks synced with the Spectro Cloud docs as of $DOCS_SYNC_DATE"

if [[ -z "$REGION" ]]; then
  warn "No AWS region found in AWS_REGION, AWS_DEFAULT_REGION, or profile '$AWS_PROFILE'. Regional EKS calls may fail."
fi

# ─── Role ARNs and the account that holds the Palette role ───────────────────
DEPLOYER_ROLE_ARN="${ARN_PREFIX}:iam::${ACCOUNT_ID}:role/${DEPLOYER_ROLE_NAME}"
HUBBLE_ROLE_ARN="${ARN_PREFIX}:iam::${ACCOUNT_ID}:role/${HUBBLE_ROLE_NAME}"
IDENTITY_ROLE_ARN="${ARN_PREFIX}:iam::${ACCOUNT_ID}:role/${IDENTITY_ROLE_NAME}"
TARGET_DEPLOYER_ARN=""
TARGET_HUBBLE_ARN=""
if [[ -n "$TARGET_ACCOUNT_ID" ]]; then
  TARGET_DEPLOYER_ARN="${ARN_PREFIX}:iam::${TARGET_ACCOUNT_ID}:role/${TARGET_DEPLOYER_ROLE_NAME}"
  TARGET_HUBBLE_ARN="${ARN_PREFIX}:iam::${TARGET_ACCOUNT_ID}:role/${TARGET_HUBBLE_ROLE_NAME}"
fi

# In the documented Pod Identity cross-account model, the Palette role (with
# the required IAM policies) and the Hubble target role live in the target
# account. Only the identity and Hubble local roles live in this account.
POD_IDENTITY_CROSS_ACCOUNT=false
if [[ "$AUTH_MODE" == "pod-identity" && -n "$TARGET_ACCOUNT_ID" ]]; then
  POD_IDENTITY_CROSS_ACCOUNT=true
fi

PALETTE_PROFILE="$AWS_PROFILE"
PALETTE_ACCOUNT_ID="$ACCOUNT_ID"
PALETTE_ROLE_NAME="$DEPLOYER_ROLE_NAME"
PALETTE_ROLE_ARN="$DEPLOYER_ROLE_ARN"
PALETTE_CONTEXT_AVAILABLE=true
TARGET_PROFILE_OK=false

if [[ "$POD_IDENTITY_CROSS_ACCOUNT" == true ]]; then
  PALETTE_ACCOUNT_ID="$TARGET_ACCOUNT_ID"
  PALETTE_ROLE_NAME="$TARGET_DEPLOYER_ROLE_NAME"
  PALETTE_ROLE_ARN="$TARGET_DEPLOYER_ARN"
  PALETTE_PROFILE="$TARGET_AWS_PROFILE"
  info "Cross-account Pod Identity: Palette role is '$TARGET_DEPLOYER_ROLE_NAME' in target account $TARGET_ACCOUNT_ID"

  if [[ -z "$TARGET_AWS_PROFILE" ]]; then
    PALETTE_CONTEXT_AVAILABLE=false
    warn "TARGET_AWS_PROFILE not set — Palette and Hubble target-role checks in account $TARGET_ACCOUNT_ID will be skipped"
  else
    TARGET_CALLER_ACCOUNT=$(aws_as "$TARGET_AWS_PROFILE" sts get-caller-identity --query Account --output text 2>"$ERR_FILE" || true)
    if [[ "$TARGET_CALLER_ACCOUNT" == "$TARGET_ACCOUNT_ID" ]]; then
      TARGET_PROFILE_OK=true
      pass "TARGET_AWS_PROFILE '$TARGET_AWS_PROFILE' resolves to target account $TARGET_ACCOUNT_ID"
    else
      PALETTE_CONTEXT_AVAILABLE=false
      fail "TARGET_AWS_PROFILE '$TARGET_AWS_PROFILE' resolves to account '${TARGET_CALLER_ACCOUNT:-$(last_error)}', not $TARGET_ACCOUNT_ID" \
        "Point TARGET_AWS_PROFILE at credentials for account $TARGET_ACCOUNT_ID, or clear it to skip target-account checks."
    fi
  fi
elif [[ -n "$TARGET_AWS_PROFILE" ]]; then
  info "TARGET_AWS_PROFILE is used only for Pod Identity cross-account checks; ignoring it for auth mode '$AUTH_MODE'"
fi

# Profile used by the simulation helpers. Sections that inspect target-account
# roles switch it temporarily.
SIM_PROFILE="$AWS_PROFILE"

# ─── Helper: check a single IAM action via simulate-principal-policy ─────────
# Usage: check_permission <principal-arn> <action> <resource> [remediation]
check_permission() {
  local principal="$1" action="$2" resource="$3"
  local remediation="${4:-Allow '$action' on '$resource' for $principal. Also check permission boundaries and organization SCPs for an explicit deny.}"
  local result
  if ! result=$(AWS_PROFILE="$SIM_PROFILE" aws iam simulate-principal-policy \
      --policy-source-arn "$principal" \
      --action-names "$action" \
      --resource-arns "$resource" \
      --query 'EvaluationResults[0].EvalDecision' \
      --output text 2>"$ERR_FILE"); then
    fail "Unable to simulate $action for $principal: $(last_error)" \
      "Grant the current caller 'iam:SimulatePrincipalPolicy', verify the role and resource ARN, and retry the simulation with AWS CLI --debug to reveal the underlying API error."
    return 0
  fi
  if [[ "$result" == "allowed" ]]; then
    pass "$action  →  allowed"
  else
    fail "$action  →  $result  (resource: $resource)" "$remediation"
  fi
  return 0
}

# ─── Helper: check a batch of actions for a given principal ──────────────────
# Usage: check_permissions_batch [--hint TEXT] <principal-arn> <resource> <action>...
check_permissions_batch() {
  local hint=""
  if [[ "$1" == "--hint" ]]; then
    hint=" $2"; shift 2
  fi
  local principal="$1"; shift
  local resource="$1"; shift
  local results
  if ! results=$(AWS_PROFILE="$SIM_PROFILE" aws iam simulate-principal-policy \
    --policy-source-arn "$principal" \
    --action-names "$@" \
    --resource-arns "$resource" \
    --query 'EvaluationResults[].{Action:EvalActionName,Decision:EvalDecision}' \
    --output json 2>"$ERR_FILE"); then
    fail "Unable to simulate permissions for $principal: $(last_error)" \
      "Grant the current caller 'iam:SimulatePrincipalPolicy', verify the role exists, and retry the AWS CLI command with --debug if the error persists."
    return 0
  fi
  local row action decision
  while IFS= read -r row; do
    action=$(echo "$row" | jq -r '.Action')
    decision=$(echo "$row" | jq -r '.Decision')
    if [[ "$decision" == "allowed" ]]; then
      pass "$action"
    else
      fail "$action  →  $decision  (resource: $resource)" \
        "Allow '$action' on '$resource' for $principal.${hint} Also inspect permission boundaries and organization SCPs."
    fi
  done < <(echo "$results" | jq -c '.[]')
  return 0
}

# ─── Helper: list denied actions without counting failures ───────────────────
# Prints one denied action per line. Returns 1 if the simulation itself fails.
simulate_denied() {
  local principal="$1" resource="$2"; shift 2
  local results
  results=$(AWS_PROFILE="$SIM_PROFILE" aws iam simulate-principal-policy \
    --policy-source-arn "$principal" \
    --action-names "$@" \
    --resource-arns "$resource" \
    --query 'EvaluationResults[].{Action:EvalActionName,Decision:EvalDecision}' \
    --output json 2>"$ERR_FILE") || return 1
  echo "$results" | jq -r '.[] | select(.Decision != "allowed") | .Action'
}

# ─── Resolve caller identity ─────────────────────────────────────────────────
header "Caller Identity (Current Credentials)"
CALLER_ARN=$(aws sts get-caller-identity --query Arn --output text)
info "Caller ARN  : $CALLER_ARN"

# ─── Section 1: Credential Baseline ──────────────────────────────────────────
header "Section 1: Credential Baseline Validation"

info "Verifying sts:GetCallerIdentity..."
if aws sts get-caller-identity &>/dev/null; then
  pass "sts:GetCallerIdentity succeeded"
else
  fail "sts:GetCallerIdentity failed — credentials may be invalid" \
    "Authenticate AWS profile '$AWS_PROFILE', then run 'aws sts get-caller-identity --profile $AWS_PROFILE' to confirm the session is valid."
fi

# ─── Section 2: EKS Deployment Permissions (Palette / cloud-account role) ────
header "Section 2: EKS Deployment Permissions (${PERMISSION_PROFILE}; ${PLACEMENT_MODE} placement)"

# Actions in both the Minimum EKS Dynamic and Minimum EKS Static policies.
EC2_COMMON_ACTIONS=(
  "ec2:DescribeInstances"
  "ec2:DescribeRegions"
  "ec2:DescribeAvailabilityZones"
  "ec2:DescribeVpcs"
  "ec2:DescribeSubnets"
  "ec2:DescribeRouteTables"
  "ec2:DescribeSecurityGroups"
  "ec2:DescribeNatGateways"
  "ec2:DescribeNetworkInterfaces"
  "ec2:DescribeKeyPairs"
  "ec2:DescribeAddresses"
  "ec2:DescribeTags"
  "ec2:CreateTags"
  "ec2:CreateSecurityGroup"
  "ec2:DeleteSecurityGroup"
  "ec2:AuthorizeSecurityGroupIngress"
)

# Actions only in the Minimum EKS Dynamic policy.
EC2_DYNAMIC_ACTIONS=(
  "ec2:CreateVpc"
  "ec2:DeleteVpc"
  "ec2:ModifyVpcAttribute"
  "ec2:DescribeVpcAttribute"
  "ec2:DescribeVpcEndpoints"
  "ec2:CreateSubnet"
  "ec2:DeleteSubnet"
  "ec2:ModifySubnetAttribute"
  "ec2:CreateRouteTable"
  "ec2:DeleteRouteTable"
  "ec2:AssociateRouteTable"
  "ec2:DisassociateRouteTable"
  "ec2:CreateRoute"
  "ec2:CreateInternetGateway"
  "ec2:DeleteInternetGateway"
  "ec2:AttachInternetGateway"
  "ec2:DetachInternetGateway"
  "ec2:DescribeInternetGateways"
  "ec2:CreateNatGateway"
  "ec2:DeleteNatGateway"
  "ec2:AllocateAddress"
  "ec2:ReleaseAddress"
  "ec2:DeleteNetworkInterface"
  "ec2:DescribeVolumes"
)

# Actions only in the Minimum EKS Static policy.
EC2_STATIC_ACTIONS=(
  "ec2:DeleteTags"
)

# EKS actions are simulated against sample cluster and node group ARNs because
# the core policies scope them to arn:*:eks:*:*:cluster/* and nodegroup/*/*/*,
# which a literal "*" resource does not match.
EKS_CLUSTER_ACTIONS=(
  "eks:CreateCluster"
  "eks:DeleteCluster"
  "eks:DescribeCluster"
  "eks:CreateNodegroup"
  "eks:TagResource"
  "eks:ListAddons"
)
EKS_NODEGROUP_ACTIONS=(
  "eks:DescribeNodegroup"
  "eks:DeleteNodegroup"
)

# IAMClusterRoles statement (Minimum EKS Dynamic, November 3, 2026). The core
# policies grant these actions too, except iam:PassRole on these role names.
IAM_CLUSTER_ROLE_ACTIONS=(
  "iam:CreateRole"
  "iam:DeleteRole"
  "iam:GetRole"
  "iam:TagRole"
  "iam:AttachRolePolicy"
  "iam:DetachRolePolicy"
  "iam:ListAttachedRolePolicies"
  "iam:PutRolePolicy"
  "iam:DeleteRolePolicy"
  "iam:ListRolePolicies"
)

# ASGManagement statement (Minimum EKS Dynamic, November 3, 2026).
ASG_MANAGEMENT_ACTIONS=(
  "autoscaling:CreateOrUpdateTags"
  "autoscaling:DeleteTags"
  "autoscaling:UpdateAutoScalingGroup"
  "autoscaling:StartInstanceRefresh"
  "autoscaling:CancelInstanceRefresh"
)

# ASGDescribeMore statement (Minimum EKS Dynamic, November 3, 2026).
ASG_DESCRIBE_MORE_ACTIONS=(
  "autoscaling:DescribeInstanceRefreshes"
  "autoscaling:DescribeTags"
)

check_deployment_permissions() {
  local principal="$1" account="$2"
  local eks_cluster_arn="${ARN_PREFIX}:eks:${SAMPLE_REGION}:${account}:cluster/palette-validation-sample"
  local eks_nodegroup_arn="${ARN_PREFIX}:eks:${SAMPLE_REGION}:${account}:nodegroup/palette-validation-sample/palette-validation-ng/00000000-0000-0000-0000-000000000000"
  local oidc_arn="${ARN_PREFIX}:iam::${account}:oidc-provider/oidc.eks.${SAMPLE_REGION}.amazonaws.com/id/PALETTEVALIDATIONSAMPLE"
  local capa_pattern="${ARN_PREFIX}:iam::${account}:role/*.cluster-api-provider-aws.sigs.k8s.io"
  local policy_source="Spectro Cloud ${PERMISSION_PROFILE} policy"
  if [[ "$PERMISSION_PROFILE" == "core" ]]; then
    policy_source="Spectro Cloud core IAM policies"
  fi

  # 2a. EC2 permissions common to dynamic and static placement
  info "Checking common EC2 permissions..."
  check_permissions_batch --hint "See the EC2Permissions statement in the ${policy_source}." \
    "$principal" "*" "${EC2_COMMON_ACTIONS[@]}"

  # 2b/2c. Placement-specific EC2 permissions
  if [[ "$PLACEMENT_MODE" == "dynamic" ]]; then
    info "Checking dynamic-placement EC2 permissions..."
    check_permissions_batch --hint "See the EC2Permissions statement in the ${policy_source}." \
      "$principal" "*" "${EC2_DYNAMIC_ACTIONS[@]}"
  else
    info "Checking static-placement EC2 permissions..."
    check_permissions_batch --hint "See the EC2Permissions statement in the ${policy_source}." \
      "$principal" "*" "${EC2_STATIC_ACTIONS[@]}"
  fi

  # 2d. EKS core permissions
  info "Checking core EKS permissions (sample cluster and node group ARNs)..."
  check_permissions_batch "$principal" "$eks_cluster_arn" "${EKS_CLUSTER_ACTIONS[@]}"
  check_permissions_batch "$principal" "$eks_nodegroup_arn" "${EKS_NODEGROUP_ACTIONS[@]}"

  # 2e. Palette-role EKS add-on permissions.
  # Spectro's minimum Pod Identity supplement grants only DescribeAddonVersions,
  # CreateAddon, and UpdateAddon to the Palette role. DescribeAddon and
  # DeleteAddon are part of the core/controller policy rather than the minimum
  # Palette-role supplement.
  if [[ "$AUTH_MODE" == "pod-identity" ]]; then
    local addon_actions
    if [[ "$PERMISSION_PROFILE" == "core" ]]; then
      addon_actions=(
        "eks:DescribeAddonVersions"
        "eks:DescribeAddon"
        "eks:CreateAddon"
        "eks:DeleteAddon"
        "eks:UpdateAddon"
      )
    else
      addon_actions=(
        "eks:DescribeAddonVersions"
        "eks:CreateAddon"
        "eks:UpdateAddon"
      )
    fi
    info "Checking $PERMISSION_PROFILE Palette-role EKS add-on permissions..."
    check_permissions_batch "$principal" "*" "${addon_actions[@]}"
  else
    info "Skipping Pod Identity addon permissions for auth mode '$AUTH_MODE'"
  fi

  # 2f. OIDC provider permissions
  info "Checking OIDC provider permissions..."
  local oidc_fix="Allow the IAM OpenID Connect provider actions on '${ARN_PREFIX}:iam::*:oidc-provider/*' for $principal."
  if [[ "$PARTITION" != "aws" ]]; then
    oidc_fix="${oidc_fix} The Spectro Cloud minimum EKS policies scope this statement to 'arn:aws:iam::*:oidc-provider/*', which never matches in partition '$PARTITION'. Change the Resource to '${ARN_PREFIX}:iam::*:oidc-provider/*' or 'arn:*:iam::*:oidc-provider/*'."
  fi
  check_permission "$principal" "iam:ListOpenIDConnectProviders" "*"
  check_permission "$principal" "iam:CreateOpenIDConnectProvider" "$oidc_arn" "$oidc_fix"
  check_permission "$principal" "iam:GetOpenIDConnectProvider"    "$oidc_arn" "$oidc_fix"
  check_permission "$principal" "iam:DeleteOpenIDConnectProvider" "$oidc_arn" "$oidc_fix"
  check_permission "$principal" "iam:TagOpenIDConnectProvider"    "$oidc_arn" "$oidc_fix"

  # 2g. IAM role permissions (scoped to CAPA naming pattern)
  info "Checking IAM role permissions (CAPA naming pattern)..."
  local capa_fix
  if [[ "$principal" == *":role/"* ]]; then
    capa_fix="Render and attach the reusable CAPA policy to the role: aws iam put-role-policy --role-name '${principal##*/}' --policy-name 'PaletteCAPAPassRole' --policy-document \"\$(bash '${SCRIPT_DIR}/render-capa-policy.sh')\" --profile '$SIM_PROFILE'."
  else
    capa_fix="Allow iam:PassRole on '$capa_pattern' for '$principal'. Render policies/capa-passrole-policy.template.json with render-capa-policy.sh, then attach it to the IAM user represented by the static credentials."
  fi
  check_permission "$principal" "iam:GetRole"                 "$capa_pattern"
  check_permission "$principal" "iam:PassRole"                "$capa_pattern" "$capa_fix"
  check_permission "$principal" "iam:ListAttachedRolePolicies" "$capa_pattern"

  # 2h. Autoscaling permissions
  info "Checking autoscaling permissions..."
  check_permission "$principal" "autoscaling:DescribeAutoScalingGroups" "*"

  # 2i. Statements added to the Minimum EKS Dynamic policy on November 3, 2026.
  # The core policies cover the same actions (except iam:PassRole on the EKS
  # cluster and node group role names). The static policy has none of them.
  if [[ "$PERMISSION_PROFILE" == "minimum-static" ]]; then
    return 0
  fi

  local cluster_role_arn="${ARN_PREFIX}:iam::${account}:role/palette-validation-iam-service-role"
  local nodegroup_role_arn="${ARN_PREFIX}:iam::${account}:role/ng-role_palette-validation"
  local slr_eks="${ARN_PREFIX}:iam::${account}:role/aws-service-role/eks.amazonaws.com/AWSServiceRoleForAmazonEKS"
  local slr_nodegroup="${ARN_PREFIX}:iam::${account}:role/aws-service-role/eks-nodegroup.amazonaws.com/AWSServiceRoleForAmazonEKSNodegroup"
  local slr_fargate="${ARN_PREFIX}:iam::${account}:role/aws-service-role/eks-fargate-pods.amazonaws.com/AWSServiceRoleForAmazonEKSForFargate"
  local managed_policy_arn="${ARN_PREFIX}:iam::aws:policy/AmazonEKSClusterPolicy"
  local ssm_arn="${ARN_PREFIX}:ssm:${SAMPLE_REGION}:${account}:parameter/aws/service/eks/optimized-ami/1.31/amazon-linux-2/recommended/image_id"
  local asg_arn="${ARN_PREFIX}:autoscaling:${SAMPLE_REGION}:${account}:autoScalingGroup:00000000-0000-0000-0000-000000000000:autoScalingGroupName/palette-validation-sample"

  info "Checking EKS cluster and node group IAM role permissions (*-iam-service-role, ng-role_*)..."
  check_permissions_batch --hint "See the IAMClusterRoles statement in the ${policy_source}." \
    "$principal" "$cluster_role_arn" "${IAM_CLUSTER_ROLE_ACTIONS[@]}"
  check_permissions_batch --hint "See the IAMClusterRoles statement in the ${policy_source}." \
    "$principal" "$nodegroup_role_arn" "${IAM_CLUSTER_ROLE_ACTIONS[@]}"
  if [[ "$PERMISSION_PROFILE" == "minimum-dynamic" ]]; then
    check_permission "$principal" "iam:PassRole" "$cluster_role_arn" \
      "Allow iam:PassRole on 'arn:*:iam::*:role/*-iam-service-role' for $principal. See the IAMClusterRoles statement in the Minimum EKS Dynamic policy."
    check_permission "$principal" "iam:PassRole" "$nodegroup_role_arn" \
      "Allow iam:PassRole on 'arn:*:iam::*:role/ng-role_*' for $principal. See the IAMClusterRoles statement in the Minimum EKS Dynamic policy."
  fi

  info "Checking AWS managed policy read, EKS service-linked roles, and EKS AMI lookup..."
  check_permission "$principal" "iam:GetPolicy" "$managed_policy_arn" \
    "Allow iam:GetPolicy on 'arn:*:iam::aws:policy/*' for $principal (IAMAWSManagedPolicyRead statement)."
  check_permission "$principal" "iam:CreateServiceLinkedRole" "$slr_eks" \
    "Allow iam:CreateServiceLinkedRole on the AWSServiceRoleForAmazonEKS service-linked role (EKSServiceLinkedRoles statement)."
  check_permission "$principal" "iam:CreateServiceLinkedRole" "$slr_nodegroup" \
    "Allow iam:CreateServiceLinkedRole on the AWSServiceRoleForAmazonEKSNodegroup service-linked role (EKSServiceLinkedRoles statement)."
  check_permission "$principal" "iam:GetRole" "$slr_eks" \
    "Allow iam:GetRole on the EKS service-linked roles (EKSServiceLinkedRoleRead statement)."
  check_permission "$principal" "iam:GetRole" "$slr_nodegroup" \
    "Allow iam:GetRole on the EKS service-linked roles (EKSServiceLinkedRoleRead statement)."
  check_permission "$principal" "iam:GetRole" "$slr_fargate" \
    "Allow iam:GetRole on the EKS service-linked roles (EKSServiceLinkedRoleRead statement)."
  check_permission "$principal" "ssm:GetParameter" "$ssm_arn" \
    "Allow ssm:GetParameter on 'arn:*:ssm:*:*:parameter/aws/service/eks/optimized-ami/*' for $principal (EKSOptimizedAMILookup statement)."

  info "Checking Auto Scaling group management permissions..."
  check_permissions_batch --hint "See the ASGManagement statement in the ${policy_source}." \
    "$principal" "$asg_arn" "${ASG_MANAGEMENT_ACTIONS[@]}"
  check_permissions_batch --hint "See the ASGDescribeMore statement in the ${policy_source}." \
    "$principal" "*" "${ASG_DESCRIBE_MORE_ACTIONS[@]}"
  return 0
}

# Resolve the principal whose deployment permissions should be simulated.
VALIDATION_PRINCIPAL_ARN=""
if [[ "$AUTH_MODE" == "secret" ]]; then
  if [[ "$CALLER_ARN" == ${ARN_PREFIX}:iam::*:user/* ]]; then
    VALIDATION_PRINCIPAL_ARN="$CALLER_ARN"
  else
    fail "Secret mode requires long-lived credentials for an IAM user, but the caller is: $CALLER_ARN" \
      "Configure AWS_PROFILE with the same access key and secret key stored for Palette. If this profile assumes a role or uses temporary credentials, select AUTH_MODE='sts' instead. Root credentials are not supported."
  fi
elif [[ "$PALETTE_CONTEXT_AVAILABLE" != true ]]; then
  warn "Skipping Palette-role permission checks: '$PALETTE_ROLE_NAME' is in target account $TARGET_ACCOUNT_ID"
  warn "  Set TARGET_AWS_PROFILE to a profile for account $TARGET_ACCOUNT_ID to simulate it"
elif aws_as "$PALETTE_PROFILE" iam get-role --role-name "$PALETTE_ROLE_NAME" >/dev/null 2>"$ERR_FILE"; then
  pass "IAM role '$PALETTE_ROLE_NAME' exists in account $PALETTE_ACCOUNT_ID"
  VALIDATION_PRINCIPAL_ARN="$PALETTE_ROLE_ARN"
else
  fail "IAM role '$PALETTE_ROLE_NAME' not found in account $PALETTE_ACCOUNT_ID — create it before deploying Palette VerteX ($(last_error))" \
    "Confirm the role name and account in the config. If correct, create the role with the required Palette permission and trust policies."
fi
info "Permission principal: ${VALIDATION_PRINCIPAL_ARN:-<unresolved>}"

if [[ -n "$VALIDATION_PRINCIPAL_ARN" ]]; then
  SIM_PROFILE="$PALETTE_PROFILE"
  check_deployment_permissions "$VALIDATION_PRINCIPAL_ARN" "$PALETTE_ACCOUNT_ID"
  SIM_PROFILE="$AWS_PROFILE"
fi

# ─── Pod Identity trust helpers ──────────────────────────────────────────────
# jq definitions shared by the trust policy checks. Statement, Principal, and
# Action may each be a string or an array.
JQ_TRUST_DEFS='
  def statements: [.Statement] | flatten;
  def actions: [.Action] | flatten;
  def has_action($a): (actions | map(select(. == $a)) | length) > 0;
  def pods_principal: ([.Principal.Service? // empty] | flatten | map(select(. == "pods.eks.amazonaws.com")) | length) > 0;
  def aws_principal($arns): ([.Principal.AWS? // empty] | flatten | map(select(. as $p | ($arns | map(select(. == $p)) | length) > 0)) | length) > 0;
'

# Usage: validate_pod_identity_trust <role-name> [profile] [account-id]
validate_pod_identity_trust() {
  local role_name="$1" profile="${2:-$AWS_PROFILE}" account="${3:-$ACCOUNT_ID}"
  local role_arn="${ARN_PREFIX}:iam::${account}:role/${role_name}"

  info "Checking role: $role_name ($role_arn)"

  # 3a. Role must exist
  local trust_doc
  trust_doc=$(aws_as "$profile" iam get-role --role-name "$role_name" \
    --query 'Role.AssumeRolePolicyDocument' --output json 2>/dev/null || echo "null")

  if [[ "$trust_doc" == "null" ]]; then
    fail "Role '$role_name' not found in account $account" \
      "Confirm the configured role name and AWS account. If absent, create '$role_name' and add an EKS Pod Identity trust statement like policies/trust-policy.json."
    return 0
  fi
  pass "Role '$role_name' exists"

  # 3b. Trust policy must allow pods.eks.amazonaws.com to sts:AssumeRole + sts:TagSession
  local has_pod_principal has_assume has_tag
  has_pod_principal=$(echo "$trust_doc" | jq -r "$JQ_TRUST_DEFS"'
    [statements[] | select(.Effect == "Allow" and pods_principal)] | length > 0')
  has_assume=$(echo "$trust_doc" | jq -r "$JQ_TRUST_DEFS"'
    [statements[] | select(.Effect == "Allow" and pods_principal and has_action("sts:AssumeRole"))] | length > 0')
  has_tag=$(echo "$trust_doc" | jq -r "$JQ_TRUST_DEFS"'
    [statements[] | select(.Effect == "Allow" and pods_principal and has_action("sts:TagSession"))] | length > 0')

  if [[ "$has_pod_principal" == "true" ]]; then
    pass "Trust policy allows pods.eks.amazonaws.com"
  else
    fail "Trust policy does NOT allow pods.eks.amazonaws.com — Pod Identity will not work" \
      "Update the trust policy for '$role_name' to include an Allow statement with Service 'pods.eks.amazonaws.com'; use policies/trust-policy.json as a reference without replacing unrelated trust statements."
  fi

  if [[ "$has_assume" == "true" ]]; then
    pass "Trust policy includes sts:AssumeRole for EKS Pod Identity"
  else
    fail "Trust policy missing sts:AssumeRole for pods.eks.amazonaws.com" \
      "Add 'sts:AssumeRole' to the actions allowed for the pods.eks.amazonaws.com principal in the '$role_name' trust policy."
  fi

  if [[ "$has_tag" == "true" ]]; then
    pass "Trust policy includes sts:TagSession for EKS Pod Identity"
  else
    fail "Trust policy missing sts:TagSession for pods.eks.amazonaws.com" \
      "Add 'sts:TagSession' to the actions allowed for the pods.eks.amazonaws.com principal in the '$role_name' trust policy."
  fi
  return 0
}

# Checks a target-account role's trust in a local role, including the
# sts:ExternalId values from the Spectro Cloud cross-account docs.
# Usage: validate_cross_account_trust <role-name> <trusted-role-arn> <newline-separated external IDs>
validate_cross_account_trust() {
  local role_name="$1" trusted_arn="$2" expected_ids="$3"
  local trusted_root="${ARN_PREFIX}:iam::${ACCOUNT_ID}:root"
  local trust_doc
  trust_doc=$(aws_as "$TARGET_AWS_PROFILE" iam get-role --role-name "$role_name" \
    --query 'Role.AssumeRolePolicyDocument' --output json 2>/dev/null || echo "null")
  if [[ "$trust_doc" == "null" ]]; then
    fail "Role '$role_name' not found in target account $TARGET_ACCOUNT_ID" \
      "Create '$role_name' in account $TARGET_ACCOUNT_ID with the trust and permissions policies from the Spectro Cloud EKS Pod Identity cross-account prerequisites."
    return 0
  fi

  local arns_json has_assume has_tag external_ids
  arns_json=$(jq -cn --arg a "$trusted_arn" --arg b "$trusted_root" '[$a, $b]')
  has_assume=$(echo "$trust_doc" | jq -r --argjson arns "$arns_json" "$JQ_TRUST_DEFS"'
    [statements[] | select(.Effect == "Allow" and aws_principal($arns) and has_action("sts:AssumeRole"))] | length > 0')
  has_tag=$(echo "$trust_doc" | jq -r --argjson arns "$arns_json" "$JQ_TRUST_DEFS"'
    [statements[] | select(.Effect == "Allow" and aws_principal($arns) and has_action("sts:TagSession"))] | length > 0')
  external_ids=$(echo "$trust_doc" | jq -r --argjson arns "$arns_json" "$JQ_TRUST_DEFS"'
    [statements[] | select(.Effect == "Allow" and aws_principal($arns) and has_action("sts:AssumeRole"))
     | (.Condition? // {}) | .[]? | .["sts:ExternalId"]? // empty] | flatten | .[]')

  if [[ "$has_assume" == "true" ]]; then
    pass "'$role_name' trust policy allows '$trusted_arn' to sts:AssumeRole"
  else
    fail "'$role_name' trust policy does not allow '$trusted_arn' to sts:AssumeRole" \
      "In account $TARGET_ACCOUNT_ID, add an Allow statement for Principal AWS '$trusted_arn' with sts:AssumeRole to the '$role_name' trust policy, as shown in the Spectro Cloud cross-account prerequisites."
  fi
  if [[ "$has_tag" == "true" ]]; then
    pass "'$role_name' trust policy allows '$trusted_arn' to sts:TagSession"
  else
    fail "'$role_name' trust policy does not allow '$trusted_arn' to sts:TagSession" \
      "In account $TARGET_ACCOUNT_ID, add an Allow statement for Principal AWS '$trusted_arn' with sts:TagSession to the '$role_name' trust policy."
  fi

  if [[ -z "$CLUSTER_NAME" || -z "$REGION" ]]; then
    info "Skipping sts:ExternalId checks for '$role_name': CLUSTER_NAME and the AWS region are needed to compute the expected values"
  elif [[ -z "$external_ids" ]]; then
    warn "'$role_name' trust policy has no sts:ExternalId condition for '$trusted_arn'. The Spectro Cloud docs scope sts:AssumeRole with:"
    while IFS= read -r expected; do
      warn "  $expected"
    done <<< "$expected_ids"
  else
    while IFS= read -r expected; do
      if grep -qxF -- "$expected" <<< "$external_ids"; then
        pass "'$role_name' trust policy includes sts:ExternalId '$expected'"
      else
        fail "'$role_name' trust policy has no sts:ExternalId '$expected'" \
          "Add a statement allowing '$trusted_arn' to sts:AssumeRole with the condition sts:ExternalId = '$expected'. Values found: $(echo "$external_ids" | tr '\n' ' ')"
      fi
    done <<< "$expected_ids"
  fi
  return 0
}

# ─── Section 3: Pod Identity — Role Existence & Trust Policy Validation ───────
if [[ "$AUTH_MODE" == "pod-identity" ]]; then
  header "Section 3: Pod Identity Role Validation"

  if [[ "$POD_IDENTITY_CROSS_ACCOUNT" == true ]]; then
    info "Cross-account mode: checking the local Hubble and identity roles. Target-role trust is checked in Section 9."
  else
    validate_pod_identity_trust "$DEPLOYER_ROLE_NAME"
  fi
  validate_pod_identity_trust "$HUBBLE_ROLE_NAME"
  validate_pod_identity_trust "$IDENTITY_ROLE_NAME"

  # ─── Section 4: Pod Identity — Permission Policy Validation ─────────────────
  header "Section 4: Pod Identity Permission Policy Checks"

  POD_IDENTITY_MGMT_ACTIONS=(
    "eks:ListPodIdentityAssociations"
    "eks:CreatePodIdentityAssociation"
    "eks:DeletePodIdentityAssociation"
  )

  # 4a. Palette role — must have Pod Identity management permissions.
  # Add-on permissions were checked once, with the selected profile, in Section 2.
  if [[ -n "$VALIDATION_PRINCIPAL_ARN" ]]; then
    info "Checking '$PALETTE_ROLE_NAME' Pod Identity management permissions..."
    SIM_PROFILE="$PALETTE_PROFILE"
    check_permissions_batch "$PALETTE_ROLE_ARN" "*" "${POD_IDENTITY_MGMT_ACTIONS[@]}"
    check_permission "$PALETTE_ROLE_ARN" "iam:PassRole" "*" \
      "Attach the bundled policy to '$PALETTE_ROLE_NAME': aws iam put-role-policy --role-name '$PALETTE_ROLE_NAME' --policy-name 'PalettePodIdentityManagement' --policy-document 'file://${SCRIPT_DIR}/policies/deployerv2-passrole.json' --profile '$PALETTE_PROFILE'. If it remains denied, inspect the role's permissions boundary and organization SCPs."
    SIM_PROFILE="$AWS_PROFILE"
  else
    warn "Skipping Palette-role Pod Identity management checks (Palette role unavailable; see Section 2)"
  fi

  # 4b. Hubble — IAM validation, EC2 describe, EKS describe, KMS read.
  # In cross-account mode these permissions belong to the Hubble target role.
  HUBBLE_IAM_ACTIONS=(
    "iam:GetRole"
    "iam:ListAttachedRolePolicies"
    "iam:ListRolePolicies"
    "iam:GetRolePolicy"
    "iam:GetPolicy"
    "iam:GetPolicyVersion"
  )
  HUBBLE_EC2_ACTIONS=(
    "ec2:DescribeRegions"
    "ec2:DescribeAvailabilityZones"
    "ec2:DescribeVpcs"
    "ec2:DescribeSubnets"
    "ec2:DescribeRouteTables"
    "ec2:DescribeKeyPairs"
  )
  HUBBLE_EKS_ACTIONS=(
    "eks:DescribeCluster"
    "eks:ListClusters"
    "eks:DescribeNodegroup"
    "eks:ListNodegroups"
    "eks:DescribeAddon"
    "eks:ListAddons"
  )
  HUBBLE_KMS_ACTIONS=(
    "kms:ListKeys"
    "kms:ListAliases"
    "kms:DescribeKey"
    "kms:GetKeyPolicy"
    "kms:GetKeyRotationStatus"
  )

  HUBBLE_READ_PRINCIPAL=""
  HUBBLE_READ_PROFILE="$AWS_PROFILE"
  if [[ "$POD_IDENTITY_CROSS_ACCOUNT" != true ]]; then
    HUBBLE_READ_PRINCIPAL="$HUBBLE_ROLE_ARN"
  elif [[ "$TARGET_PROFILE_OK" == true ]]; then
    if aws_as "$TARGET_AWS_PROFILE" iam get-role --role-name "$TARGET_HUBBLE_ROLE_NAME" >/dev/null 2>"$ERR_FILE"; then
      HUBBLE_READ_PRINCIPAL="$TARGET_HUBBLE_ARN"
      HUBBLE_READ_PROFILE="$TARGET_AWS_PROFILE"
    else
      fail "Hubble target role '$TARGET_HUBBLE_ROLE_NAME' not found in account $TARGET_ACCOUNT_ID ($(last_error))" \
        "Create '$TARGET_HUBBLE_ROLE_NAME' in account $TARGET_ACCOUNT_ID with the Hubble target-role trust and permissions policies from the Spectro Cloud docs."
    fi
  else
    warn "Skipping Hubble target-role read permissions: set TARGET_AWS_PROFILE to check '$TARGET_HUBBLE_ROLE_NAME' in account $TARGET_ACCOUNT_ID"
  fi

  if [[ -n "$HUBBLE_READ_PRINCIPAL" ]]; then
    info "Checking Hubble read permissions on '${HUBBLE_READ_PRINCIPAL##*/}'..."
    SIM_PROFILE="$HUBBLE_READ_PROFILE"
    info "  IAM validation permissions..."
    check_permissions_batch "$HUBBLE_READ_PRINCIPAL" "*" "${HUBBLE_IAM_ACTIONS[@]}"
    info "  EC2 describe permissions..."
    check_permissions_batch "$HUBBLE_READ_PRINCIPAL" "*" "${HUBBLE_EC2_ACTIONS[@]}"
    info "  EKS describe permissions..."
    check_permissions_batch "$HUBBLE_READ_PRINCIPAL" "*" "${HUBBLE_EKS_ACTIONS[@]}"
    info "  KMS read permissions..."
    check_permissions_batch "$HUBBLE_READ_PRINCIPAL" "*" "${HUBBLE_KMS_ACTIONS[@]}"
    SIM_PROFILE="$AWS_PROFILE"
  fi

  # 4c. Palette identity — Pod Identity management, EC2 describe, and (same
  # account) GetRole + PassRole scoped to the Palette role.
  info "Checking palette-identity role permissions..."
  info "  Pod Identity management permissions..."
  check_permissions_batch "$IDENTITY_ROLE_ARN" "*" "${POD_IDENTITY_MGMT_ACTIONS[@]}"

  info "  EC2 describe permissions..."
  check_permission "$IDENTITY_ROLE_ARN" "ec2:DescribeInstances" "*"

  if [[ "$POD_IDENTITY_CROSS_ACCOUNT" == true ]]; then
    info "  Cross-account mode: GetRole, PassRole, AssumeRole, and TagSession on the target Palette role are checked in Section 9"
  else
    IDENTITY_FIX="Render the identity-role policy with render-identity-policy.sh and attach it: aws iam put-role-policy --role-name '$IDENTITY_ROLE_NAME' --policy-name 'PaletteIdentityPodIdentity' --policy-document \"\$(bash '${SCRIPT_DIR}/render-identity-policy.sh')\" --profile '$AWS_PROFILE'."
    info "  IAM GetRole + PassRole scoped to '$DEPLOYER_ROLE_NAME'..."
    check_permission "$IDENTITY_ROLE_ARN" "iam:GetRole"  "$DEPLOYER_ROLE_ARN" "$IDENTITY_FIX"
    check_permission "$IDENTITY_ROLE_ARN" "iam:PassRole" "$DEPLOYER_ROLE_ARN" "$IDENTITY_FIX"
  fi
else
  header "Sections 3–4: Pod Identity Validation"
  info "Skipped for auth mode '$AUTH_MODE'"
fi

# ─── Section 5: STS Validation ────────────────────────────────────────────────
header "Section 5: STS Validation"

# Usage: try_assume_role <role-arn>
try_assume_role() {
  local role_arn="$1"
  local args=(
    --role-arn "$role_arn"
    --role-session-name "palette-iam-validation-$$"
    --duration-seconds 900
    --query 'Credentials.AccessKeyId'
    --output text
  )
  local description="sts:AssumeRole"
  if [[ -n "$STS_EXTERNAL_ID" ]]; then
    args+=(--external-id "$STS_EXTERNAL_ID")
    description="$description with external ID"
  fi
  if [[ "$STS_SESSION_TAGS" == "true" ]]; then
    args+=(--tags Key=PaletteValidation,Value=true)
    description="$description and session tags"
  fi

  local key
  if key=$(aws sts assume-role "${args[@]}" 2>"$ERR_FILE") && [[ -n "$key" && "$key" != "None" ]]; then
    pass "$description into '$role_arn' succeeded (session key: ${key:0:8}...)"
  else
    local fix="Run this check with credentials for the AWS account configured for STS on your Palette/VerteX instance; the role trust policy must trust that account. The Spectro Cloud docs require an external ID: set STS_EXTERNAL_ID to the External ID shown in the Palette Add AWS Account wizard. Inspect the trust policy with: aws iam get-role --role-name '${role_arn##*/}'"
    if [[ "$STS_SESSION_TAGS" == "true" ]]; then
      fix="$fix. STS_SESSION_TAGS=true also requires sts:TagSession for the caller in the trust policy and the caller's own policies."
    fi
    fail "$description into '$role_arn' failed: $(last_error)" "$fix"
  fi
  return 0
}

if [[ "$AUTH_MODE" == "sts" ]]; then
  info "Run this mode with credentials for the AWS account configured for STS on your Palette/VerteX instance."
  if [[ -z "$STS_EXTERNAL_ID" ]]; then
    warn "STS_EXTERNAL_ID is empty. Roles created as the Spectro Cloud docs describe require the tenant's External ID, so this check will fail without it."
  fi
  info "Attempting sts:AssumeRole into $DEPLOYER_ROLE_NAME..."
  try_assume_role "$DEPLOYER_ROLE_ARN"
else
  info "Skipped for auth mode '$AUTH_MODE'; direct role assumption is only required for STS authentication"
fi

# ─── Section 6: EKS Cluster Checks (if CLUSTER_NAME is set) ──────────────────
header "Section 6: EKS Cluster Checks"

if [[ -z "$CLUSTER_NAME" ]]; then
  warn "CLUSTER_NAME not set — skipping live EKS cluster checks"
else
  # 6a. Cluster exists and is ACTIVE
  info "Checking EKS cluster '$CLUSTER_NAME'..."
  CLUSTER_STATUS=$(aws eks describe-cluster \
    --name "$CLUSTER_NAME" \
    --query 'cluster.status' \
    --output text 2>/dev/null || echo "NOT_FOUND")

  if [[ "$CLUSTER_STATUS" == "ACTIVE" ]]; then
    pass "Cluster '$CLUSTER_NAME' is ACTIVE"
  elif [[ "$CLUSTER_STATUS" == "NOT_FOUND" ]]; then
    fail "Cluster '$CLUSTER_NAME' not found" \
      "Confirm CLUSTER_NAME, AWS_PROFILE, and the region (${REGION:-not set}). Test with: aws eks describe-cluster --name '$CLUSTER_NAME' --profile '$AWS_PROFILE'"
  else
    warn "Cluster '$CLUSTER_NAME' status: $CLUSTER_STATUS"
  fi

  if [[ "$AUTH_MODE" == "pod-identity" ]]; then
    # 6b. Kubernetes version >= 1.24 (required for Pod Identity)
    K8S_VERSION=$(aws eks describe-cluster \
      --name "$CLUSTER_NAME" \
      --query 'cluster.version' \
      --output text 2>/dev/null || echo "unknown")

    if [[ ! "$K8S_VERSION" =~ ^([0-9]+)\.([0-9]+)$ ]]; then
      warn "Unable to read the Kubernetes version of '$CLUSTER_NAME' (got '$K8S_VERSION') — EKS Pod Identity requires 1.24+"
    else
      MAJOR="${BASH_REMATCH[1]}"
      MINOR="${BASH_REMATCH[2]}"
      if (( MAJOR > 1 || (MAJOR == 1 && MINOR >= 24) )); then
        pass "Kubernetes version $K8S_VERSION >= 1.24 (Pod Identity supported)"
      else
        fail "Kubernetes version $K8S_VERSION < 1.24 — EKS Pod Identity requires 1.24+" \
          "Upgrade the EKS control plane and node groups to a supported Kubernetes version before enabling Pod Identity."
      fi
    fi

    # 6c. Pod Identity agent addon is installed
    info "Checking eks-pod-identity-agent addon..."
    ADDON_STATUS=$(aws eks describe-addon \
      --cluster-name "$CLUSTER_NAME" \
      --addon-name eks-pod-identity-agent \
      --query 'addon.status' \
      --output text 2>/dev/null || echo "NOT_FOUND")

    if [[ "$ADDON_STATUS" == "ACTIVE" ]]; then
      pass "eks-pod-identity-agent addon is ACTIVE"
    elif [[ "$ADDON_STATUS" == "NOT_FOUND" ]]; then
      fail "eks-pod-identity-agent addon not installed" \
        "Install it with: aws eks create-addon --cluster-name '$CLUSTER_NAME' --addon-name eks-pod-identity-agent --profile '$AWS_PROFILE'"
    else
      warn "eks-pod-identity-agent addon status: $ADDON_STATUS"
    fi

    # 6d. Pod Identity associations exist for required service accounts
    info "Checking Pod Identity associations on cluster '$CLUSTER_NAME'..."
    ASSOCIATIONS=$(aws eks list-pod-identity-associations \
      --cluster-name "$CLUSTER_NAME" \
      --query 'associations[].{NS:namespace,SA:serviceAccount,Role:roleArn}' \
      --output json 2>/dev/null || echo "[]")

    check_association() {
      local ns="$1" sa="$2" label="$3" expected_role_arn="$4"
      local found
      found=$(echo "$ASSOCIATIONS" | jq -r \
        --arg ns "$ns" --arg sa "$sa" \
        '.[] | select(.NS==$ns and .SA==$sa) | .Role' 2>/dev/null | head -1)
      if [[ -z "$found" ]]; then
        fail "Pod Identity association MISSING: $label ($ns/$sa)" \
          "Create it with: aws eks create-pod-identity-association --cluster-name '$CLUSTER_NAME' --namespace '$ns' --service-account '$sa' --role-arn '$expected_role_arn' --profile '$AWS_PROFILE'"
      elif [[ "$found" == "$expected_role_arn" ]]; then
        pass "Pod Identity association found: $label ($ns/$sa → $found)"
      else
        warn "Pod Identity association $label ($ns/$sa) uses '$found', not the configured '$expected_role_arn' — verify this is intentional"
      fi
      return 0
    }

    check_association "hubble-system" "spectro-hubble" "spectro-hubble" "$HUBBLE_ROLE_ARN"
    check_association "palette-identity" "palette-identity" "palette-identity" "$IDENTITY_ROLE_ARN"
  else
    info "Skipping Pod Identity version, addon, and association checks for auth mode '$AUTH_MODE'"
  fi

  # 6e. OIDC provider is configured for the cluster. The IAM provider ARN is
  # built from the issuer host, so it does not depend on the configured region.
  info "Checking OIDC provider for cluster '$CLUSTER_NAME'..."
  OIDC_ISSUER=$(aws eks describe-cluster \
    --name "$CLUSTER_NAME" \
    --query 'cluster.identity.oidc.issuer' \
    --output text 2>/dev/null || echo "None")

  if [[ "$OIDC_ISSUER" != "None" && -n "$OIDC_ISSUER" ]]; then
    pass "OIDC issuer configured: $OIDC_ISSUER"

    OIDC_ARN="${ARN_PREFIX}:iam::${ACCOUNT_ID}:oidc-provider/${OIDC_ISSUER#https://}"
    if aws iam get-open-id-connect-provider --open-id-connect-provider-arn "$OIDC_ARN" &>/dev/null; then
      pass "OIDC provider registered in IAM: $OIDC_ARN"
    else
      warn "OIDC provider for the management cluster is NOT registered in IAM: $OIDC_ARN"
      warn "  EKS Pod Identity does not need it; register it only if workloads on this cluster use IAM roles for service accounts (IRSA)."
    fi
  else
    fail "No OIDC issuer found on cluster '$CLUSTER_NAME'" \
      "Verify that '$CLUSTER_NAME' is the intended EKS cluster and that the caller can run eks:DescribeCluster. Re-run 'aws eks describe-cluster --name $CLUSTER_NAME --query cluster.identity.oidc'."
  fi
fi

# ─── Section 7: Partition-Specific ARN Validation ─────────────────────────────
header "Section 7: Partition-Specific ARN Validation"

info "Validating ARN prefix consistency for partition: $PARTITION"

# 7a. Confirm all role ARNs use the correct partition prefix
# Usage: validate_arn_partition <role-name> [profile]
validate_arn_partition() {
  local role_name="$1" profile="${2:-$AWS_PROFILE}"
  local role_arn
  role_arn=$(aws_as "$profile" iam get-role --role-name "$role_name" \
    --query 'Role.Arn' --output text 2>/dev/null || echo "NOT_FOUND")

  if [[ "$role_arn" == "NOT_FOUND" ]]; then
    warn "Role '$role_name' not found — skipping ARN partition check"
    return 0
  fi

  if [[ "$role_arn" == ${ARN_PREFIX}:* ]]; then
    pass "Role '$role_name' ARN uses correct partition prefix '$ARN_PREFIX': $role_arn"
  else
    fail "Role '$role_name' ARN uses WRONG partition prefix. Expected '$ARN_PREFIX', got: $role_arn" \
      "Correct PARTITION and AWS_PROFILE so they target the same AWS partition. IAM role ARNs cannot change partition; use or create the role in the intended partition."
  fi
  return 0
}

case "$AUTH_MODE" in
  secret)
    if [[ -n "$VALIDATION_PRINCIPAL_ARN" ]]; then
      if [[ "$VALIDATION_PRINCIPAL_ARN" == ${ARN_PREFIX}:* ]]; then
        pass "Static credential principal uses correct partition prefix '$ARN_PREFIX': $VALIDATION_PRINCIPAL_ARN"
      else
        fail "Static credential principal uses the wrong partition: $VALIDATION_PRINCIPAL_ARN" \
          "Correct PARTITION and AWS_PROFILE so the configured static credentials belong to the intended AWS partition."
      fi
    fi
    ;;
  sts)
    validate_arn_partition "$DEPLOYER_ROLE_NAME"
    ;;
  pod-identity)
    if [[ "$POD_IDENTITY_CROSS_ACCOUNT" != true ]]; then
      validate_arn_partition "$DEPLOYER_ROLE_NAME"
    elif [[ "$PALETTE_CONTEXT_AVAILABLE" == true ]]; then
      validate_arn_partition "$TARGET_DEPLOYER_ROLE_NAME" "$TARGET_AWS_PROFILE"
    fi
    validate_arn_partition "$HUBBLE_ROLE_NAME"
    validate_arn_partition "$IDENTITY_ROLE_NAME"
    ;;
esac

# 7b. GovCloud-specific checks
if [[ "$PARTITION" == "aws-us-gov" ]]; then
  info "GovCloud partition detected — running additional checks..."

  if [[ "$REGION" == us-gov-* ]]; then
    pass "AWS region '$REGION' is a valid GovCloud region"
  else
    fail "AWS region '${REGION:-<not set>}' does not appear to be a GovCloud region (expected us-gov-east-1 or us-gov-west-1)" \
      "Set a GovCloud region, for example: aws configure set region us-gov-west-1 --profile '$AWS_PROFILE' (or export AWS_REGION=us-gov-west-1)"
  fi

  # Palette SaaS does not support GovCloud — VerteX is required
  warn "GovCloud partition is ONLY supported by Palette VerteX, not Palette SaaS."
  warn "Ensure you are deploying a self-hosted VerteX instance, not a Palette SaaS-connected cluster."
fi

# ─── Section 8: CAPA Roles and CloudFormation Stack Management ───────────────
header "Section 8: CAPA Roles and CloudFormation Stack Management"

# Roles created by the Spectro Cloud CloudFormation template
# (palette-cloudformation-input-template.yaml).
CAPA_STACK_ROLES=(
  "control-plane.cluster-api-provider-aws.sigs.k8s.io"
  "controllers.cluster-api-provider-aws.sigs.k8s.io"
  "eks-controlplane.cluster-api-provider-aws.sigs.k8s.io"
  "nodes.cluster-api-provider-aws.sigs.k8s.io"
)
# Roles that cluster profiles may reference through roleName but that the
# template does not create.
CAPA_OPTIONAL_ROLES=(
  "eks-nodegroup.cluster-api-provider-aws.sigs.k8s.io"
  "eks-fargate.cluster-api-provider-aws.sigs.k8s.io"
)
# Option 1 (automatic CloudFormation stack management) policy.
CFN_STACK_ACTIONS=(
  "cloudformation:CreateStack"
  "cloudformation:DescribeStacks"
  "cloudformation:UpdateStack"
  "cloudformation:DescribeStackEvents"
  "cloudformation:DescribeStackResources"
  "cloudformation:ListStackResources"
  "cloudformation:GetTemplate"
  "cloudformation:ContinueUpdateRollback"
  "cloudformation:DeleteStack"
  "iam:CreateRole"
  "iam:AttachRolePolicy"
  "iam:TagRole"
  "iam:UntagRole"
  "iam:UpdateAssumeRolePolicy"
  "iam:GetPolicyVersion"
  "iam:CreatePolicyVersion"
  "iam:DeletePolicyVersion"
  "iam:GetPolicy"
  "iam:ListPolicyVersions"
  "iam:GetRole"
  "iam:GetInstanceProfile"
  "iam:DetachRolePolicy"
  "iam:CreatePolicy"
  "iam:TagPolicy"
  "iam:CreateInstanceProfile"
  "iam:AddRoleToInstanceProfile"
  "iam:TagInstanceProfile"
  "iam:DeletePolicy"
  "iam:DeleteRole"
  "iam:DeleteInstanceProfile"
  "iam:RemoveRoleFromInstanceProfile"
)

if [[ "$PALETTE_CONTEXT_AVAILABLE" != true ]]; then
  warn "Skipping CAPA role checks: they live in target account $TARGET_ACCOUNT_ID; set TARGET_AWS_PROFILE to check them"
else
  info "Checking for CAPA roles created by the Palette CloudFormation stack in account $PALETTE_ACCOUNT_ID..."
  MISSING_CAPA_ROLES=0
  for capa_role in "${CAPA_STACK_ROLES[@]}"; do
    if aws_as "$PALETTE_PROFILE" iam get-role --role-name "$capa_role" &>/dev/null; then
      pass "CAPA role exists: $capa_role"
    else
      warn "CAPA role NOT found: $capa_role"
      MISSING_CAPA_ROLES=$((MISSING_CAPA_ROLES+1))
    fi
  done
  for capa_role in "${CAPA_OPTIONAL_ROLES[@]}"; do
    if aws_as "$PALETTE_PROFILE" iam get-role --role-name "$capa_role" &>/dev/null; then
      info "Optional CAPA role exists: $capa_role"
    else
      info "Optional CAPA role not found: $capa_role (only needed if a cluster profile sets it as roleName; the stack does not create it)"
    fi
  done

  CFN_DENIED=""
  CFN_SIMULATED=false
  if [[ -n "$VALIDATION_PRINCIPAL_ARN" ]]; then
    SIM_PROFILE="$PALETTE_PROFILE"
    if CFN_DENIED=$(simulate_denied "$VALIDATION_PRINCIPAL_ARN" "*" "${CFN_STACK_ACTIONS[@]}"); then
      CFN_SIMULATED=true
    else
      warn "Unable to simulate CloudFormation stack permissions: $(last_error)"
    fi
    SIM_PROFILE="$AWS_PROFILE"
  fi
  CFN_DENIED_COUNT=0
  if [[ -n "$CFN_DENIED" ]]; then
    CFN_DENIED_COUNT=$(echo "$CFN_DENIED" | wc -l | tr -d ' ')
  fi
  CFN_FIX_OPTION2="Create the stack manually (Option 2): aws cloudformation create-stack --stack-name cluster-api-provider-aws-sigs-k8s-io --template-body file://palette-cloudformation-input-template.yaml --capabilities CAPABILITY_NAMED_IAM --region ${REGION:-<region>}, then set manageCloudFormationStackManually.enabled: true in your cluster profiles."
  CFN_FIX_OPTION1="Or attach the Option 1 CloudFormation stack permissions policy from the Spectro Cloud minimum permissions docs so Palette can manage the stack."

  if [[ "$CFN_SIMULATED" != true ]]; then
    if [[ "$MISSING_CAPA_ROLES" -gt 0 ]]; then
      warn "$MISSING_CAPA_ROLES CAPA role(s) missing. Palette creates them only if it manages the CloudFormation stack (Option 1)."
      warn "  $CFN_FIX_OPTION2"
    fi
  elif [[ "$MISSING_CAPA_ROLES" -gt 0 && "$CFN_DENIED_COUNT" -eq 0 ]]; then
    pass "$MISSING_CAPA_ROLES CAPA role(s) missing, but the Palette principal can manage the CloudFormation stack (Option 1) and will create them"
  elif [[ "$MISSING_CAPA_ROLES" -gt 0 ]]; then
    fail "$MISSING_CAPA_ROLES CAPA role(s) missing and the Palette principal lacks $CFN_DENIED_COUNT Option 1 CloudFormation stack permission(s): $(echo "$CFN_DENIED" | tr '\n' ' ')" \
      "$CFN_FIX_OPTION2 $CFN_FIX_OPTION1"
  elif [[ "$CFN_DENIED_COUNT" -eq 0 ]]; then
    info "All CAPA stack roles exist, and the Palette principal can also manage the CloudFormation stack (Option 1)"
  else
    info "All CAPA stack roles exist. The Palette principal lacks Option 1 stack permissions ($CFN_DENIED_COUNT), which is expected when you manage the stack manually (Option 2) with manageCloudFormationStackManually.enabled: true"
  fi
fi

# ─── Section 9: Cross-Account Validation (optional) ───────────────────────────
header "Section 9: Cross-Account Validation"

CROSS_ACCOUNT_ACTIONS=(
  "iam:GetRole"
  "iam:PassRole"
  "sts:AssumeRole"
  "sts:TagSession"
)

if [[ "$AUTH_MODE" == "secret" ]]; then
  info "Skipped for secret authentication; static credentials do not assume a target role"
elif [[ -z "$TARGET_ACCOUNT_ID" ]]; then
  warn "TARGET_ACCOUNT_ID not set — skipping cross-account checks"
  warn "  Set TARGET_ACCOUNT_ID=<account-id> to validate cross-account role assumption"
elif [[ "$AUTH_MODE" == "sts" ]]; then
  info "Attempting cross-account sts:AssumeRole into: $TARGET_DEPLOYER_ARN"
  try_assume_role "$TARGET_DEPLOYER_ARN"
else
  info "Validating Pod Identity cross-account roles (management account $ACCOUNT_ID → target account $TARGET_ACCOUNT_ID)..."

  info "Simulating identity role permissions on the target Palette role..."
  check_permissions_batch --hint "See the identity service IAM local role in the Spectro Cloud cross-account prerequisites." \
    "$IDENTITY_ROLE_ARN" "$TARGET_DEPLOYER_ARN" "${CROSS_ACCOUNT_ACTIONS[@]}"
  info "Simulating identity role permissions on itself (self-reference required by the docs)..."
  check_permissions_batch --hint "The identity local role policy must list its own ARN as a Resource." \
    "$IDENTITY_ROLE_ARN" "$IDENTITY_ROLE_ARN" "${CROSS_ACCOUNT_ACTIONS[@]}"

  info "Simulating Hubble role permissions on the target Hubble role..."
  check_permissions_batch --hint "See the Hubble service IAM local role in the Spectro Cloud cross-account prerequisites." \
    "$HUBBLE_ROLE_ARN" "$TARGET_HUBBLE_ARN" "${CROSS_ACCOUNT_ACTIONS[@]}"

  if [[ "$TARGET_PROFILE_OK" == true ]]; then
    info "Checking target-role trust policies in account $TARGET_ACCOUNT_ID..."
    EXTERNAL_ID_BASE="${REGION}/${ACCOUNT_ID}/${CLUSTER_NAME}"
    validate_pod_identity_trust "$TARGET_DEPLOYER_ROLE_NAME" "$TARGET_AWS_PROFILE" "$TARGET_ACCOUNT_ID"
    validate_cross_account_trust "$TARGET_DEPLOYER_ROLE_NAME" "$IDENTITY_ROLE_ARN" \
      "$(printf '%s\n%s' "${EXTERNAL_ID_BASE}/palette-identity/palette-identity" "${EXTERNAL_ID_BASE}/*/palette-manager")"
    validate_cross_account_trust "$TARGET_HUBBLE_ROLE_NAME" "$HUBBLE_ROLE_ARN" \
      "${EXTERNAL_ID_BASE}/hubble-system/spectro-hubble"
  else
    warn "Target-role trust policies were not checked; set TARGET_AWS_PROFILE to a profile for account $TARGET_ACCOUNT_ID"
  fi
fi

# ─── Section 10: palette-global-config ConfigMap Check ────────────────────────
header "Section 10: palette-global-config ConfigMap (Pod Identity Prerequisite)"

if [[ "$AUTH_MODE" != "pod-identity" ]]; then
  info "Skipped for auth mode '$AUTH_MODE'"
elif [[ -z "$CLUSTER_NAME" ]]; then
  warn "CLUSTER_NAME not set — skipping ConfigMap check"
else
  info "Checking for palette-global-config ConfigMap in kube-system..."

  # Requires kubectl configured for the management cluster
  if ! command -v kubectl &>/dev/null; then
    warn "kubectl not found — skipping ConfigMap check"
  else
    CM_VALUE=$(kubectl get configmap palette-global-config \
      -n kube-system \
      -o jsonpath='{.data.managementClusterName}' 2>/dev/null || echo "NOT_FOUND")

    if [[ "$CM_VALUE" == "NOT_FOUND" || -z "$CM_VALUE" ]]; then
      fail "ConfigMap 'palette-global-config' in kube-system is missing or does not contain 'managementClusterName'" \
        "Create or update it with: kubectl create configmap palette-global-config -n kube-system --from-literal=managementClusterName='$CLUSTER_NAME' --dry-run=client -o yaml | kubectl apply -f -"
    else
      pass "ConfigMap 'palette-global-config' found with managementClusterName='$CM_VALUE'"
      if [[ "$CM_VALUE" == "$CLUSTER_NAME" ]]; then
        pass "managementClusterName matches CLUSTER_NAME ('$CLUSTER_NAME')"
      else
        warn "managementClusterName ('$CM_VALUE') does not match CLUSTER_NAME ('$CLUSTER_NAME') — verify this is intentional"
      fi
    fi
  fi
fi

# ─── Section 11: Pod Identity Environment Variable Verification ───────────────
header "Section 11: Pod Identity Environment Variable Verification"

if [[ "$AUTH_MODE" != "pod-identity" ]]; then
  info "Skipped for auth mode '$AUTH_MODE'"
elif ! command -v kubectl &>/dev/null; then
  warn "kubectl not found — skipping Pod Identity env var checks"
else
  check_pod_identity_env() {
    local namespace="$1" selector="$2" service_account="$3" label="$4"
    local pod_name pod_env env_var

    info "Checking $label pods for Pod Identity env vars..."
    if ! pod_name=$(kubectl get pods -n "$namespace" \
      -l "$selector" \
      -o jsonpath='{.items[0].metadata.name}' 2>/dev/null); then
      warn "Unable to query $label pods using the current kubectl context — skipping this runtime check"
    elif [[ -z "$pod_name" ]]; then
      warn "No pods found in $namespace with label '$selector' — skipping this runtime check"
    else
      info "Inspecting Pod Identity env vars on pod '$pod_name'..."
      if ! pod_env=$(kubectl get pod "$pod_name" -n "$namespace" \
        -o jsonpath='{.spec.containers[*].env[*].name}' 2>/dev/null); then
        warn "Unable to inspect pod '$pod_name' — skipping this runtime check"
        return 0
      fi
      pod_env=$(echo "$pod_env" | tr ' ' '\n')

      for env_var in AWS_CONTAINER_CREDENTIALS_FULL_URI AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE; do
        if echo "$pod_env" | grep -qx "$env_var"; then
          pass "Pod '$pod_name' has env var: $env_var"
        else
          fail "Pod '$pod_name' is MISSING env var: $env_var — Pod Identity mutation may not have occurred" \
            "Verify the pod uses service account '$service_account', confirm its EKS Pod Identity association and the eks-pod-identity-agent are ACTIVE, then restart the workload so EKS can inject the variables into a new pod."
        fi
      done
    fi
    return 0
  }

  check_pod_identity_env "hubble-system" "app=spectro-hubble" "spectro-hubble" "spectro-hubble"
  check_pod_identity_env "palette-identity" "app=palette-identity" "palette-identity" "palette-identity"
fi

# ─── Final Summary ─────────────────────────────────────────────────────────────
header "Validation Summary"

if [[ "$FAILURES" -eq 0 ]]; then
  echo -e "\n${GREEN}${BOLD}  ✅  All checks passed! Your environment is ready for Palette VerteX on EKS.${RESET}\n"
else
  echo -e "\n${RED}${BOLD}  ❌  $FAILURES check(s) FAILED. Review the output above and remediate before deploying.${RESET}\n"
  echo -e "${YELLOW}  Each failure above includes a targeted FIX. After applying the relevant fixes, rerun this script.${RESET}"
  echo -e "${YELLOW}  Additional troubleshooting checklist:${RESET}"
  echo -e "  1. Attach the permission policies from the Spectro Cloud IAM policy docs (synced $DOCS_SYNC_DATE)"
  echo -e "  2. Confirm the AWS profile, account, partition, and region match the intended environment"
  case "$AUTH_MODE" in
    secret)
      echo -e "  3. Confirm the configured access key belongs to the validated IAM user"
      ;;
    sts)
      echo -e "  3. Run with the Palette/VerteX STS account's credentials and set STS_EXTERNAL_ID to the tenant External ID"
      echo -e "  4. Confirm the role trust policy trusts that account with the sts:ExternalId condition"
      ;;
    pod-identity)
      echo -e "  3. Ensure Pod Identity roles trust pods.eks.amazonaws.com for sts:AssumeRole and sts:TagSession"
      echo -e "  4. Confirm the eks-pod-identity-agent addon and service-account associations are active"
      echo -e "  5. Set managementClusterName in palette-global-config and restart workloads after association changes"
      if [[ "$POD_IDENTITY_CROSS_ACCOUNT" == true ]]; then
        echo -e "  6. In the target account, confirm the Palette and Hubble target roles trust the local identity and Hubble roles"
      fi
      ;;
  esac
  echo
  exit 1
fi
