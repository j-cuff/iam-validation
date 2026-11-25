#!/usr/bin/env bash
# =============================================================================
# setup-iam.sh
#
# Creates or updates the AWS IAM roles, policies, and EKS Pod Identity
# associations that Spectro Cloud Palette VerteX needs for STS or EKS Pod
# Identity authentication. It applies the policies published in the Spectro
# Cloud docs (policies/spectro-docs) and reads the same validate-iam.conf as
# validate-iam.sh. Run the validator afterwards.
#
# By default the script only prints its plan. Pass --apply to make changes.
#
# Changes are additive. The script creates missing roles and policies, adds
# missing trust statements (keeping any others), updates the managed policies
# it created, attaches policies, and creates or updates Pod Identity
# associations. It never deletes or detaches roles or policies, and it never
# modifies a managed policy it did not create. When one of its managed
# policies already has five versions, it deletes the oldest non-default
# version before adding a new one (AWS keeps at most five).
#
# Usage:
#   ./setup-iam.sh [sts|pod-identity] [--apply]
#   CONFIG_FILE=/path/to/validate-iam.conf ./setup-iam.sh --apply
# =============================================================================

set -euo pipefail

DOCS_SYNC_DATE="2026-11-20"
MANAGED_TAG_KEY="ManagedBy"
MANAGED_TAG_VALUE="iam-validation-setup"
CFN_STACK_NAME="cluster-api-provider-aws-sigs-k8s-io"

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
CONFIG_FILE="${CONFIG_FILE:-${SCRIPT_DIR}/validate-iam.conf}"
POLICY_DIR="${SCRIPT_DIR}/policies/spectro-docs"

usage() {
  cat <<EOF
Usage: $0 [sts|pod-identity] [--apply]

Sets up the IAM roles, policies, and Pod Identity associations for Palette
VerteX using the settings in validate-iam.conf (or CONFIG_FILE).

  sts | pod-identity   Override AUTH_MODE from the configuration.
  --apply              Make the changes. Without it, only the plan is printed.
  -h, --help           Show this help.
EOF
}

APPLY=false
MODE_ARG=""
for arg in "$@"; do
  case "$arg" in
    --apply) APPLY=true ;;
    -h|--help) usage; exit 0 ;;
    secret|sts|pod-identity)
      if [[ -n "$MODE_ARG" ]]; then usage >&2; exit 2; fi
      MODE_ARG="$arg"
      ;;
    *) echo "ERROR: Unknown argument '$arg'" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "ERROR: Configuration file not found: $CONFIG_FILE" >&2
  echo "Create one with: cp '${SCRIPT_DIR}/validate-iam.conf.example' '${SCRIPT_DIR}/validate-iam.conf'" >&2
  exit 1
fi

# shellcheck source=/dev/null
source "$CONFIG_FILE"

if [[ -z "${AWS_PROFILE:-}" ]]; then
  echo "ERROR: AWS_PROFILE is not set in $CONFIG_FILE" >&2
  exit 1
fi
export AWS_PROFILE

AUTH_MODE="${MODE_ARG:-${AUTH_MODE:-}}"
PARTITION="${PARTITION:-aws}"
CLUSTER_NAME="${CLUSTER_NAME:-}"
ACCOUNT_ID="${ACCOUNT_ID:-}"
DEPLOYER_ROLE_NAME="${DEPLOYER_ROLE_NAME:-SpectroCloudPaletteRole}"
HUBBLE_ROLE_NAME="${HUBBLE_ROLE_NAME:-SpectroCloudHubbleRole}"
IDENTITY_ROLE_NAME="${IDENTITY_ROLE_NAME:-SpectroCloudIdentityRole}"
PLACEMENT_MODE="${PLACEMENT_MODE:-dynamic}"
PERMISSION_PROFILE="${PERMISSION_PROFILE:-minimum-${PLACEMENT_MODE}}"
TARGET_ACCOUNT_ID="${TARGET_ACCOUNT_ID:-}"
TARGET_DEPLOYER_ROLE_NAME="${TARGET_DEPLOYER_ROLE_NAME:-$DEPLOYER_ROLE_NAME}"
TARGET_HUBBLE_ROLE_NAME="${TARGET_HUBBLE_ROLE_NAME:-$HUBBLE_ROLE_NAME}"
TARGET_AWS_PROFILE="${TARGET_AWS_PROFILE:-}"
STS_TRUSTED_ACCOUNT_ID="${STS_TRUSTED_ACCOUNT_ID:-}"
STS_EXTERNAL_ID="${STS_EXTERNAL_ID:-}"
STS_SESSION_TAGS="${STS_SESSION_TAGS:-false}"
POLICY_NAME_SUFFIX="${POLICY_NAME_SUFFIX:-${ROLE_ID_SUFFIX:-}}"
CFN_STACK_MODE="${CFN_STACK_MODE:-palette}"
SETUP_CLUSTER_PREREQS="${SETUP_CLUSTER_PREREQS:-false}"
SETUP_RETRY_ATTEMPTS="${SETUP_RETRY_ATTEMPTS:-10}"
SETUP_RETRY_DELAY="${SETUP_RETRY_DELAY:-6}"

# ─── Output helpers ──────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

ok()     { echo -e "  ${GREEN}[OK]${RESET}   $*"; }
planned(){ echo -e "  ${CYAN}[PLAN]${RESET} $*"; }
made()   { echo -e "  ${GREEN}[DONE]${RESET} $*"; }
warn()   { echo -e "  ${YELLOW}[WARN]${RESET} $*"; }
info()   { echo -e "  ${CYAN}[INFO]${RESET} $*"; }
die()    { echo -e "${RED}ERROR: $*${RESET}" >&2; exit 1; }
header() { echo -e "\n${BOLD}${CYAN}══════════════════════════════════════════${RESET}"; \
           echo -e "${BOLD}${CYAN}  $*${RESET}"; \
           echo -e "${BOLD}${CYAN}══════════════════════════════════════════${RESET}"; }

WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/setup-iam.XXXXXX")
ERR_FILE="$WORK_DIR/stderr"
trap 'rm -rf "$WORK_DIR"' EXIT

last_error() {
  local line
  line=$(grep -v '^[[:space:]]*$' "$ERR_FILE" 2>/dev/null | head -1 || true)
  echo "${line:-no error output}"
}

aws_as() {
  local profile="$1"; shift
  AWS_PROFILE="$profile" aws "$@"
}

# ─── Validate settings ───────────────────────────────────────────────────────
case "$AUTH_MODE" in
  sts|pod-identity) ;;
  secret)
    die "Secret mode uses an IAM user's long-lived access keys, so there are no roles to set up. Attach the policies in policies/spectro-docs to that IAM user, then run ./validate-iam.sh secret."
    ;;
  *) die "Unknown AUTH_MODE '$AUTH_MODE'. Valid for setup: sts | pod-identity" ;;
esac

case "$PERMISSION_PROFILE" in
  core|minimum-dynamic|minimum-static) ;;
  *) die "Unknown PERMISSION_PROFILE '$PERMISSION_PROFILE'. Valid: core | minimum-dynamic | minimum-static" ;;
esac
if [[ "$PERMISSION_PROFILE" == "minimum-dynamic" && "$PLACEMENT_MODE" != "dynamic" ]] ||
   [[ "$PERMISSION_PROFILE" == "minimum-static" && "$PLACEMENT_MODE" != "static" ]]; then
  die "PERMISSION_PROFILE '$PERMISSION_PROFILE' conflicts with PLACEMENT_MODE '$PLACEMENT_MODE'."
fi
case "$CFN_STACK_MODE" in
  palette|manual|none) ;;
  *) die "CFN_STACK_MODE must be palette, manual, or none, not '$CFN_STACK_MODE'." ;;
esac
case "$SETUP_CLUSTER_PREREQS" in
  true|false) ;;
  *) die "SETUP_CLUSTER_PREREQS must be true or false, not '$SETUP_CLUSTER_PREREQS'." ;;
esac
case "$STS_SESSION_TAGS" in
  true|false) ;;
  *) die "STS_SESSION_TAGS must be true or false, not '$STS_SESSION_TAGS'." ;;
esac

case "$PARTITION" in
  aws)         ARN_PREFIX="arn:aws" ;;
  aws-us-gov)  ARN_PREFIX="arn:aws-us-gov" ;;
  aws-iso)     ARN_PREFIX="arn:aws-iso" ;;
  aws-iso-b)   ARN_PREFIX="arn:aws-iso-b" ;;
  *) die "Unknown partition '$PARTITION'. Valid: aws | aws-us-gov | aws-iso | aws-iso-b" ;;
esac

# These values are substituted into policy documents, so restrict them to the
# characters AWS allows for each kind of value.
check_value() {
  local label="$1" value="$2" pattern="$3"
  if [[ -n "$value" && ! "$value" =~ $pattern ]]; then
    die "$label '$value' is not valid."
  fi
}
ROLE_PATTERN='^[A-Za-z0-9+=,.@_-]{1,64}$'
check_value "ACCOUNT_ID" "$ACCOUNT_ID" '^[0-9]{12}$'
check_value "TARGET_ACCOUNT_ID" "$TARGET_ACCOUNT_ID" '^[0-9]{12}$'
check_value "STS_TRUSTED_ACCOUNT_ID" "$STS_TRUSTED_ACCOUNT_ID" '^[0-9]{12}$'
check_value "DEPLOYER_ROLE_NAME" "$DEPLOYER_ROLE_NAME" "$ROLE_PATTERN"
check_value "HUBBLE_ROLE_NAME" "$HUBBLE_ROLE_NAME" "$ROLE_PATTERN"
check_value "IDENTITY_ROLE_NAME" "$IDENTITY_ROLE_NAME" "$ROLE_PATTERN"
check_value "TARGET_DEPLOYER_ROLE_NAME" "$TARGET_DEPLOYER_ROLE_NAME" "$ROLE_PATTERN"
check_value "TARGET_HUBBLE_ROLE_NAME" "$TARGET_HUBBLE_ROLE_NAME" "$ROLE_PATTERN"
check_value "POLICY_NAME_SUFFIX" "$POLICY_NAME_SUFFIX" '^[A-Za-z0-9+=,.@_-]{1,64}$'
check_value "CLUSTER_NAME" "$CLUSTER_NAME" '^[0-9A-Za-z][A-Za-z0-9_-]{0,99}$'
# macOS regex caps repeat counts at 255, so the External ID length is checked separately.
check_value "STS_EXTERNAL_ID" "$STS_EXTERNAL_ID" '^[A-Za-z0-9+=,.@:/_-]+$'
if [[ -n "$STS_EXTERNAL_ID" ]] && (( ${#STS_EXTERNAL_ID} < 2 || ${#STS_EXTERNAL_ID} > 1224 )); then
  die "STS_EXTERNAL_ID must be 2 to 1224 characters long."
fi
[[ "$SETUP_RETRY_ATTEMPTS" =~ ^[0-9]+$ && "$SETUP_RETRY_DELAY" =~ ^[0-9]+$ ]] ||
  die "SETUP_RETRY_ATTEMPTS and SETUP_RETRY_DELAY must be whole numbers."

POD_IDENTITY_CROSS_ACCOUNT=false
if [[ "$AUTH_MODE" == "pod-identity" && -n "$TARGET_ACCOUNT_ID" ]]; then
  POD_IDENTITY_CROSS_ACCOUNT=true
fi

# ─── Pre-flight ──────────────────────────────────────────────────────────────
if [[ "$APPLY" == true ]]; then
  header "Applying IAM setup ($AUTH_MODE)"
else
  header "IAM setup plan ($AUTH_MODE) — no changes will be made"
fi

command -v aws &>/dev/null || die "aws CLI not found. Install it first."
command -v jq &>/dev/null || die "jq not found. Install it first."
[[ -d "$POLICY_DIR" ]] || die "Docs policies not found in $POLICY_DIR"

CALLER_ACCOUNT=$(aws sts get-caller-identity --query Account --output text 2>"$ERR_FILE") ||
  die "Cannot use AWS profile '$AWS_PROFILE': $(last_error)"
if [[ -z "$ACCOUNT_ID" ]]; then
  ACCOUNT_ID="$CALLER_ACCOUNT"
elif [[ "$ACCOUNT_ID" != "$CALLER_ACCOUNT" ]]; then
  die "ACCOUNT_ID is $ACCOUNT_ID, but profile '$AWS_PROFILE' is account $CALLER_ACCOUNT. Setup creates roles in the profile's account."
fi

REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-}}"
if [[ -z "$REGION" ]]; then
  REGION=$(aws configure get region 2>/dev/null || true)
fi
check_value "region" "$REGION" '^[a-z0-9-]+$'

info "Account     : $ACCOUNT_ID ($PARTITION)"
info "Region      : ${REGION:-<not set>}"
info "Cluster     : ${CLUSTER_NAME:-<not set — Pod Identity associations will be skipped>}"
info "Permissions : $PERMISSION_PROFILE ($PLACEMENT_MODE placement)"
info "CloudFormation stack: $CFN_STACK_MODE"
info "Policies    : Spectro Cloud docs as of $DOCS_SYNC_DATE"

if [[ "$AUTH_MODE" == "sts" ]]; then
  [[ -n "$STS_TRUSTED_ACCOUNT_ID" ]] ||
    die "STS mode needs STS_TRUSTED_ACCOUNT_ID: the AWS account ID shown in the Palette Add AWS Account wizard (the account configured for STS on your Palette/VerteX instance)."
  [[ -n "$STS_EXTERNAL_ID" ]] ||
    die "STS mode needs STS_EXTERNAL_ID: the External ID shown in the Palette Add AWS Account wizard."
fi

if [[ "$POD_IDENTITY_CROSS_ACCOUNT" == true ]]; then
  [[ -n "$TARGET_AWS_PROFILE" ]] ||
    die "Cross-account Pod Identity needs TARGET_AWS_PROFILE: a profile for target account $TARGET_ACCOUNT_ID, where the Palette and Hubble target roles are created."
  [[ -n "$CLUSTER_NAME" && -n "$REGION" ]] ||
    die "Cross-account Pod Identity needs CLUSTER_NAME and a region: they are part of the sts:ExternalId values in the target roles' trust policies."
fi

if [[ -n "$TARGET_ACCOUNT_ID" && -n "$TARGET_AWS_PROFILE" ]]; then
  TARGET_CALLER_ACCOUNT=$(aws_as "$TARGET_AWS_PROFILE" sts get-caller-identity --query Account --output text 2>"$ERR_FILE") ||
    die "Cannot use TARGET_AWS_PROFILE '$TARGET_AWS_PROFILE': $(last_error)"
  [[ "$TARGET_CALLER_ACCOUNT" == "$TARGET_ACCOUNT_ID" ]] ||
    die "TARGET_AWS_PROFILE '$TARGET_AWS_PROFILE' is account $TARGET_CALLER_ACCOUNT, not TARGET_ACCOUNT_ID $TARGET_ACCOUNT_ID."
  info "Target      : $TARGET_ACCOUNT_ID (profile $TARGET_AWS_PROFILE)"
fi

DEPLOYER_ROLE_ARN="${ARN_PREFIX}:iam::${ACCOUNT_ID}:role/${DEPLOYER_ROLE_NAME}"
HUBBLE_ROLE_ARN="${ARN_PREFIX}:iam::${ACCOUNT_ID}:role/${HUBBLE_ROLE_NAME}"
IDENTITY_ROLE_ARN="${ARN_PREFIX}:iam::${ACCOUNT_ID}:role/${IDENTITY_ROLE_NAME}"
TARGET_DEPLOYER_ARN="${ARN_PREFIX}:iam::${TARGET_ACCOUNT_ID}:role/${TARGET_DEPLOYER_ROLE_NAME}"
TARGET_HUBBLE_ARN="${ARN_PREFIX}:iam::${TARGET_ACCOUNT_ID}:role/${TARGET_HUBBLE_ROLE_NAME}"

# ─── Making changes ──────────────────────────────────────────────────────────
CHANGES=0
PENDING_ROLES=" "

# Run (or, without --apply, only report) one change. Retries errors caused by
# IAM's eventual consistency, such as a trust policy naming a role created
# seconds earlier.
# Usage: change <description> <profile> <command> [args...]
change() {
  local description="$1" profile="$2"; shift 2
  CHANGES=$((CHANGES+1))
  if [[ "$APPLY" != true ]]; then
    planned "$description"
    return 0
  fi
  local attempt=1
  while true; do
    if AWS_PROFILE="$profile" "$@" >/dev/null 2>"$ERR_FILE"; then
      made "$description"
      return 0
    fi
    if (( attempt < SETUP_RETRY_ATTEMPTS )) &&
       grep -qE 'MalformedPolicyDocument|Invalid principal|InvalidParameterException|NoSuchEntity|ConcurrentModification' "$ERR_FILE"; then
      warn "$(last_error) — retrying in ${SETUP_RETRY_DELAY}s (IAM changes can take a few seconds to propagate)"
      sleep "$SETUP_RETRY_DELAY"
      attempt=$((attempt+1))
      continue
    fi
    echo -e "  ${RED}[FAIL]${RESET} $description: $(last_error)"
    die "Stopped because later steps depend on this one. Fix the cause and re-run; completed steps are skipped."
  done
}

# Without --apply, roles that would be created do not exist yet, so reads
# against them are skipped.
role_pending() {
  [[ "$APPLY" != true && "$PENDING_ROLES" == *" $1 "* ]]
}

# Fill a docs policy's placeholders and, outside the aws partition, replace the
# docs' hardcoded arn:aws: ARNs. Prints compact JSON.
render_policy() {
  local file="${POLICY_DIR}/$1" text
  [[ -f "$file" ]] || die "Missing docs policy $file"
  text=$(sed \
    -e "s|<partition>|${PARTITION}|g" \
    -e "s|<aws-account-id>|${ACCOUNT_ID}|g" \
    -e "s|<role-name-for-palette-iam-role>|${DEPLOYER_ROLE_NAME}|g" \
    -e "s|<target-aws-account-id>|${TARGET_ACCOUNT_ID}|g" \
    -e "s|<role-name-for-palette-iam-target-role>|${TARGET_DEPLOYER_ROLE_NAME}|g" \
    -e "s|<aws-management-cluster-account-id>|${ACCOUNT_ID}|g" \
    -e "s|<role-name-for-identity-service-iam-local-role>|${IDENTITY_ROLE_NAME}|g" \
    -e "s|<aws-management-cluster-region>|${REGION}|g" \
    -e "s|<management-cluster-name>|${CLUSTER_NAME}|g" \
    -e "s|<hubble-service-iam-target-role>|${TARGET_HUBBLE_ROLE_NAME}|g" \
    -e "s|:role/spectro-hubble-identity\"|:role/${HUBBLE_ROLE_NAME}\"|g" \
    "$file")
  if [[ "$PARTITION" != "aws" ]]; then
    text=$(printf '%s' "$text" | sed "s|arn:aws:|arn:${PARTITION}:|g")
  fi
  if grep -qE '<[a-z0-9-]+>' <<< "$text"; then
    die "Unfilled placeholder in $1: $(grep -oE '<[a-z0-9-]+>' <<< "$text" | sort -u | tr '\n' ' ')"
  fi
  printf '%s' "$text" | jq -c .
}

JQ_ACTIONS='def actions: [.Statement | ([.] | flatten)[] | .Action | ([.] | flatten)[]] | unique;'

# Adds each wanted trust statement unless an equivalent one exists. A statement
# with the same Sid but different content is replaced; all others are kept.
JQ_MERGE_TRUST='
  def arr: [.] | flatten;
  def nprincipal: if type == "object" then with_entries(.value |= (arr | sort)) else . end;
  def ncondition: if type == "object" then with_entries(.value |= with_entries(.value |= (arr | sort))) else null end;
  def n: {Effect, Principal: (.Principal | nprincipal), Action: (.Action | arr | sort), Condition: (.Condition | ncondition)};
  .Statement = (.Statement | arr)
  | reduce ($want.Statement[]) as $s (.;
      if any(.Statement[]; n == ($s | n)) then .
      elif ($s.Sid // null) != null and any(.Statement[]; (.Sid // null) == $s.Sid)
        then .Statement |= map(if (.Sid // null) == $s.Sid then $s else . end)
      else .Statement += [$s] end)'

same_json() {
  [[ "$(jq -S . <<< "$1")" == "$(jq -S . <<< "$2")" ]]
}

# Usage: ensure_role <profile> <account> <role-name> <trust-json> <description>
ensure_role() {
  local profile="$1" account="$2" name="$3" trust="$4" description="$5"
  local current merged
  if current=$(aws_as "$profile" iam get-role --role-name "$name" \
      --query 'Role.AssumeRolePolicyDocument' --output json 2>"$ERR_FILE"); then
    merged=$(jq -c --argjson want "$trust" "$JQ_MERGE_TRUST" <<< "$current")
    if same_json "$merged" "$current"; then
      ok "Role $name has the required trust statements"
    else
      change "Update the trust policy of role $name with the required statements (other statements are kept)" \
        "$profile" aws iam update-assume-role-policy --role-name "$name" --policy-document "$merged"
    fi
  elif grep -q 'NoSuchEntity' "$ERR_FILE"; then
    change "Create role $name in account $account" \
      "$profile" aws iam create-role --role-name "$name" --assume-role-policy-document "$trust" \
      --description "$description" --tags "Key=${MANAGED_TAG_KEY},Value=${MANAGED_TAG_VALUE}"
    PENDING_ROLES="${PENDING_ROLES}${account}/${name} "
  else
    die "Unable to read role $name: $(last_error)"
  fi
  return 0
}

# Creates or updates a managed policy and sets POLICY_ARN.
# Usage: ensure_managed_policy <profile> <account> <policy-name> <document-json> <source-file>
ensure_managed_policy() {
  local profile="$1" account="$2" name="$3" doc="$4" source_file="$5"
  POLICY_ARN="${ARN_PREFIX}:iam::${account}:policy/${name}"
  local default_version tags current managed missing versions oldest
  if ! default_version=$(aws_as "$profile" iam get-policy --policy-arn "$POLICY_ARN" \
      --query 'Policy.DefaultVersionId' --output text 2>"$ERR_FILE"); then
    grep -q 'NoSuchEntity' "$ERR_FILE" || die "Unable to read policy $name: $(last_error)"
    change "Create managed policy $name in account $account (from $source_file)" \
      "$profile" aws iam create-policy --policy-name "$name" --policy-document "$doc" \
      --description "Spectro Cloud docs policy ${source_file} (synced ${DOCS_SYNC_DATE}); managed by setup-iam.sh" \
      --tags "Key=${MANAGED_TAG_KEY},Value=${MANAGED_TAG_VALUE}"
    return 0
  fi
  current=$(aws_as "$profile" iam get-policy-version --policy-arn "$POLICY_ARN" --version-id "$default_version" \
    --query 'PolicyVersion.Document' --output json 2>"$ERR_FILE") || die "Unable to read policy $name: $(last_error)"
  if same_json "$current" "$doc"; then
    ok "Managed policy $name matches the docs"
    return 0
  fi
  tags=$(aws_as "$profile" iam list-policy-tags --policy-arn "$POLICY_ARN" --query 'Tags' --output json 2>"$ERR_FILE") ||
    die "Unable to read tags of policy $name: $(last_error)"
  managed=$(jq -r --arg k "$MANAGED_TAG_KEY" '[.[]? | select(.Key == $k) | .Value][0] // ""' <<< "$tags")
  if [[ "$managed" != "$MANAGED_TAG_VALUE" ]]; then
    missing=$(jq -rn --argjson want "$doc" --argjson have "$current" "$JQ_ACTIONS"' ($want | actions) - ($have | actions) | join(" ")')
    warn "Managed policy $name exists but was not created by setup-iam.sh, so it is left unchanged and attached as-is. It differs from the docs${missing:+; actions missing: $missing}"
    return 0
  fi
  versions=$(aws_as "$profile" iam list-policy-versions --policy-arn "$POLICY_ARN" --query 'Versions' --output json 2>"$ERR_FILE") ||
    die "Unable to list versions of policy $name: $(last_error)"
  if [[ "$(jq 'length' <<< "$versions")" -ge 5 ]]; then
    oldest=$(jq -r '[.[] | select(.IsDefaultVersion | not)] | sort_by(.CreateDate) | .[0].VersionId' <<< "$versions")
    change "Delete version $oldest, the oldest non-default version of managed policy $name (AWS keeps at most 5)" \
      "$profile" aws iam delete-policy-version --policy-arn "$POLICY_ARN" --version-id "$oldest"
  fi
  change "Update managed policy $name to the docs version" \
    "$profile" aws iam create-policy-version --policy-arn "$POLICY_ARN" --policy-document "$doc" --set-as-default
  return 0
}

# Usage: ensure_attached <profile> <account> <role-name> <policy-arn>
ensure_attached() {
  local profile="$1" account="$2" role="$3" policy_arn="$4" attached
  if ! role_pending "${account}/${role}"; then
    attached=$(aws_as "$profile" iam list-attached-role-policies --role-name "$role" \
      --query 'AttachedPolicies[].PolicyArn' --output json 2>"$ERR_FILE") ||
      die "Unable to list policies attached to $role: $(last_error)"
    if jq -e --arg a "$policy_arn" 'any(.[]; . == $a)' <<< "$attached" >/dev/null; then
      ok "Role $role has ${policy_arn##*/} attached"
      return 0
    fi
  fi
  change "Attach ${policy_arn##*/} to role $role" \
    "$profile" aws iam attach-role-policy --role-name "$role" --policy-arn "$policy_arn"
  return 0
}

# Usage: ensure_inline_policy <profile> <account> <role-name> <policy-name> <source-file>
ensure_inline_policy() {
  local profile="$1" account="$2" role="$3" name="$4" source_file="$5"
  local doc current
  doc=$(render_policy "$source_file")
  if ! role_pending "${account}/${role}"; then
    if current=$(aws_as "$profile" iam get-role-policy --role-name "$role" --policy-name "$name" \
        --query 'PolicyDocument' --output json 2>"$ERR_FILE"); then
      if same_json "$current" "$doc"; then
        ok "Role $role has inline policy $name matching the docs"
        return 0
      fi
      change "Update inline policy $name on role $role to the docs version (from $source_file)" \
        "$profile" aws iam put-role-policy --role-name "$role" --policy-name "$name" --policy-document "$doc"
      return 0
    fi
    grep -q 'NoSuchEntity' "$ERR_FILE" || die "Unable to read inline policy $name on $role: $(last_error)"
  fi
  change "Add inline policy $name to role $role (from $source_file)" \
    "$profile" aws iam put-role-policy --role-name "$role" --policy-name "$name" --policy-document "$doc"
  return 0
}

# The documented permission policies for the Palette role, as parallel arrays
# of managed-policy base names and docs files.
palette_policy_set() {
  PALETTE_POLICY_NAMES=()
  PALETTE_POLICY_FILES=()
  case "$PERMISSION_PROFILE" in
    core)
      PALETTE_POLICY_NAMES=(PaletteControllerPolicy PaletteControlPlanePolicy PaletteNodesPolicy PaletteDeploymentPolicy PaletteControllersEKSPolicy)
      PALETTE_POLICY_FILES=(core-controller-policy.json core-control-plane-policy.json core-nodes-policy.json core-deployment-policy.json core-controllers-eks-policy.json)
      ;;
    minimum-dynamic)
      PALETTE_POLICY_NAMES=(PaletteMinimumEKSDynamicPolicy)
      PALETTE_POLICY_FILES=(eks-dynamic-permissions.json)
      ;;
    minimum-static)
      PALETTE_POLICY_NAMES=(PaletteMinimumEKSStaticPolicy)
      PALETTE_POLICY_FILES=(eks-static-permissions.json)
      ;;
  esac
  # The core PaletteDeploymentPolicy already grants the stack permissions.
  if [[ "$CFN_STACK_MODE" == "palette" && "$PERMISSION_PROFILE" != "core" ]]; then
    PALETTE_POLICY_NAMES+=(PaletteCloudFormationStackPolicy)
    PALETTE_POLICY_FILES+=(cloudformation-stack-permissions.json)
  fi
  if [[ "$AUTH_MODE" == "pod-identity" ]]; then
    PALETTE_POLICY_NAMES+=(PalettePodIdentityPolicy)
    if [[ "$PERMISSION_PROFILE" == "core" ]]; then
      PALETTE_POLICY_FILES+=(palette-pod-identity-core.json)
    else
      PALETTE_POLICY_FILES+=(palette-pod-identity-minimum.json)
    fi
  fi
}

# Usage: setup_palette_role <profile> <account> <role-name> <trust-json> <description>
setup_palette_role() {
  local profile="$1" account="$2" role="$3" trust="$4" description="$5" i name doc
  ensure_role "$profile" "$account" "$role" "$trust" "$description"
  palette_policy_set
  for i in "${!PALETTE_POLICY_NAMES[@]}"; do
    name="${PALETTE_POLICY_NAMES[$i]}${POLICY_NAME_SUFFIX:+-${POLICY_NAME_SUFFIX}}"
    doc=$(render_policy "${PALETTE_POLICY_FILES[$i]}")
    ensure_managed_policy "$profile" "$account" "$name" "$doc" "${PALETTE_POLICY_FILES[$i]}"
    ensure_attached "$profile" "$account" "$role" "$POLICY_ARN"
  done
  return 0
}

# Option 2: create the CAPA CloudFormation stack from the docs template.
# Usage: ensure_cfn_stack <profile> <account>
ensure_cfn_stack() {
  local profile="$1" account="$2" status template="$WORK_DIR/palette-cloudformation-input-template-${2}.yaml"
  if status=$(aws_as "$profile" cloudformation describe-stacks --stack-name "$CFN_STACK_NAME" \
      --query 'Stacks[0].StackStatus' --output text 2>"$ERR_FILE"); then
    ok "CloudFormation stack $CFN_STACK_NAME exists in account $account ($status)"
    return 0
  fi
  grep -q 'does not exist' "$ERR_FILE" || die "Unable to read CloudFormation stacks: $(last_error)"
  [[ -n "$REGION" ]] || die "Creating the CloudFormation stack needs a region."
  if [[ "$PARTITION" == "aws" ]]; then
    cp "${POLICY_DIR}/palette-cloudformation-input-template.yaml" "$template"
  else
    sed "s|arn:aws:|arn:${PARTITION}:|g" "${POLICY_DIR}/palette-cloudformation-input-template.yaml" > "$template"
  fi
  change "Create CloudFormation stack $CFN_STACK_NAME in account $account, region $REGION (creates the CAPA roles)" \
    "$profile" aws cloudformation create-stack --stack-name "$CFN_STACK_NAME" \
    --template-body "file://${template}" --capabilities CAPABILITY_NAMED_IAM
  if [[ "$APPLY" == true ]]; then
    info "Waiting for the stack to finish creating..."
    aws_as "$profile" cloudformation wait stack-create-complete --stack-name "$CFN_STACK_NAME" 2>"$ERR_FILE" ||
      die "Stack $CFN_STACK_NAME did not finish creating: $(last_error). Check its events in the CloudFormation console."
    made "CloudFormation stack $CFN_STACK_NAME created"
  fi
  return 0
}

# Usage: ensure_association <namespace> <service-account> <role-arn> [target-role-arn]
ensure_association() {
  local ns="$1" sa="$2" role_arn="$3" target="${4:-}"
  local id details current_role current_target args label
  args=(--role-arn "$role_arn")
  label="$ns/$sa → ${role_arn##*/}"
  if [[ -n "$target" ]]; then
    args+=(--target-role-arn "$target")
    label="$label → ${target##*/} (account $TARGET_ACCOUNT_ID)"
  fi
  id=$(aws eks list-pod-identity-associations --cluster-name "$CLUSTER_NAME" --namespace "$ns" \
    --service-account "$sa" --query 'associations[0].associationId' --output text 2>"$ERR_FILE") ||
    die "Unable to list Pod Identity associations: $(last_error)"
  if [[ -z "$id" || "$id" == "None" ]]; then
    change "Create Pod Identity association $label" \
      "$AWS_PROFILE" aws eks create-pod-identity-association --cluster-name "$CLUSTER_NAME" \
      --namespace "$ns" --service-account "$sa" "${args[@]}"
    return 0
  fi
  details=$(aws eks describe-pod-identity-association --cluster-name "$CLUSTER_NAME" --association-id "$id" \
    --query 'association.[roleArn,targetRoleArn]' --output text 2>"$ERR_FILE") ||
    die "Unable to read Pod Identity association $id: $(last_error)"
  current_role=$(cut -f1 <<< "$details")
  current_target=$(cut -f2 <<< "$details")
  if [[ "$current_target" == "None" ]]; then current_target=""; fi
  if [[ "$current_role" == "$role_arn" && "$current_target" == "$target" ]]; then
    ok "Pod Identity association $label"
  elif [[ -z "$target" && -n "$current_target" ]]; then
    warn "Pod Identity association $ns/$sa uses target role $current_target, which this setup does not expect. Remove it yourself if it is not intended."
  else
    change "Update Pod Identity association $ns/$sa (was ${current_role##*/}${current_target:+ → ${current_target##*/}}) to $label" \
      "$AWS_PROFILE" aws eks update-pod-identity-association --cluster-name "$CLUSTER_NAME" \
      --association-id "$id" "${args[@]}"
  fi
  return 0
}

ensure_pod_identity_agent() {
  local status
  if status=$(aws eks describe-addon --cluster-name "$CLUSTER_NAME" --addon-name eks-pod-identity-agent \
      --query 'addon.status' --output text 2>"$ERR_FILE"); then
    ok "eks-pod-identity-agent add-on is installed ($status)"
    return 0
  fi
  grep -q 'ResourceNotFoundException' "$ERR_FILE" || die "Unable to read the eks-pod-identity-agent add-on: $(last_error)"
  change "Install the eks-pod-identity-agent add-on on cluster $CLUSTER_NAME" \
    "$AWS_PROFILE" aws eks create-addon --cluster-name "$CLUSTER_NAME" --addon-name eks-pod-identity-agent
  if [[ "$APPLY" == true ]]; then
    info "Waiting for the add-on to become active..."
    aws eks wait addon-active --cluster-name "$CLUSTER_NAME" --addon-name eks-pod-identity-agent 2>"$ERR_FILE" ||
      die "The eks-pod-identity-agent add-on did not become active: $(last_error)"
    made "eks-pod-identity-agent add-on is active"
  fi
  return 0
}

ensure_global_config() {
  local context server endpoint value
  if ! command -v kubectl &>/dev/null; then
    warn "kubectl not found — skipping the palette-global-config ConfigMap"
    return 0
  fi
  context=$(kubectl config current-context 2>/dev/null || true)
  server=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || true)
  endpoint=$(aws eks describe-cluster --name "$CLUSTER_NAME" --query 'cluster.endpoint' --output text 2>/dev/null || true)
  if [[ -z "$server" || "${server%/}" != "${endpoint%/}" ]]; then
    warn "kubectl context '${context:-<none>}' does not point at cluster $CLUSTER_NAME (${endpoint:-endpoint unknown}). Skipping the palette-global-config ConfigMap; switch contexts and re-run."
    return 0
  fi
  if value=$(kubectl get configmap palette-global-config -n kube-system \
      -o jsonpath='{.data.managementClusterName}' 2>"$ERR_FILE"); then
    if [[ "$value" == "$CLUSTER_NAME" ]]; then
      ok "ConfigMap kube-system/palette-global-config has managementClusterName=$CLUSTER_NAME"
    elif [[ -z "$value" ]]; then
      change "Set managementClusterName=$CLUSTER_NAME in ConfigMap kube-system/palette-global-config" \
        "$AWS_PROFILE" kubectl patch configmap palette-global-config -n kube-system --type merge \
        -p "{\"data\":{\"managementClusterName\":\"${CLUSTER_NAME}\"}}"
    else
      warn "ConfigMap kube-system/palette-global-config has managementClusterName='$value', not '$CLUSTER_NAME'. Left unchanged; correct it yourself if it is wrong."
    fi
  elif grep -q 'NotFound' "$ERR_FILE"; then
    change "Create ConfigMap kube-system/palette-global-config with managementClusterName=$CLUSTER_NAME (kubectl context '$context')" \
      "$AWS_PROFILE" kubectl create configmap palette-global-config -n kube-system \
      --from-literal=managementClusterName="$CLUSTER_NAME"
  else
    die "Unable to read ConfigMap kube-system/palette-global-config: $(last_error)"
  fi
  return 0
}

# Pod Identity associations and, optionally, the cluster prerequisites.
# Usage: setup_cluster <hubble-role-arn> <hubble-target-role-arn-or-empty> <identity-role-arn>
setup_cluster() {
  local hubble_role="$1" hubble_target="$2" identity_role="$3" status
  header "Cluster $CLUSTER_NAME: Pod Identity"
  status=$(aws eks describe-cluster --name "$CLUSTER_NAME" --query 'cluster.status' --output text 2>"$ERR_FILE") ||
    die "Cannot read cluster $CLUSTER_NAME: $(last_error)"
  info "Cluster status: $status"
  if [[ "$SETUP_CLUSTER_PREREQS" == true ]]; then
    ensure_pod_identity_agent
  fi
  ensure_association "hubble-system" "spectro-hubble" "$hubble_role" "$hubble_target"
  ensure_association "palette-identity" "palette-identity" "$identity_role"
  if [[ "$SETUP_CLUSTER_PREREQS" == true ]]; then
    ensure_global_config
  else
    info "Set SETUP_CLUSTER_PREREQS=true to also install the eks-pod-identity-agent add-on and the palette-global-config ConfigMap"
  fi
  return 0
}

# ─── STS ─────────────────────────────────────────────────────────────────────
setup_sts() {
  local trusted="${ARN_PREFIX}:iam::${STS_TRUSTED_ACCOUNT_ID}:root" trust
  trust=$(jq -cn --arg p "$trusted" --arg id "$STS_EXTERNAL_ID" '{
    Version: "2012-10-17",
    Statement: [{
      Sid: "PaletteSTSAssumeRole", Effect: "Allow", Principal: {AWS: $p},
      Action: "sts:AssumeRole", Condition: {StringEquals: {"sts:ExternalId": $id}}
    }]}')
  if [[ "$STS_SESSION_TAGS" == true ]]; then
    trust=$(jq -c --arg p "$trusted" '.Statement += [{Sid: "PaletteSTSTagSession", Effect: "Allow", Principal: {AWS: $p}, Action: "sts:TagSession"}]' <<< "$trust")
  fi

  header "Palette role for STS in account $ACCOUNT_ID"
  info "Trusts account $STS_TRUSTED_ACCOUNT_ID with the tenant External ID"
  setup_palette_role "$AWS_PROFILE" "$ACCOUNT_ID" "$DEPLOYER_ROLE_NAME" "$trust" \
    "Spectro Cloud Palette role for STS (${PERMISSION_PROFILE}); managed by setup-iam.sh"
  if [[ "$CFN_STACK_MODE" == "manual" ]]; then
    ensure_cfn_stack "$AWS_PROFILE" "$ACCOUNT_ID"
  fi

  if [[ -n "$TARGET_ACCOUNT_ID" ]]; then
    if [[ -z "$TARGET_AWS_PROFILE" ]]; then
      warn "TARGET_ACCOUNT_ID is set but TARGET_AWS_PROFILE is not, so the role in account $TARGET_ACCOUNT_ID is not set up"
    else
      header "Palette role for STS in target account $TARGET_ACCOUNT_ID"
      setup_palette_role "$TARGET_AWS_PROFILE" "$TARGET_ACCOUNT_ID" "$TARGET_DEPLOYER_ROLE_NAME" "$trust" \
        "Spectro Cloud Palette role for STS (${PERMISSION_PROFILE}); managed by setup-iam.sh"
      if [[ "$CFN_STACK_MODE" == "manual" ]]; then
        ensure_cfn_stack "$TARGET_AWS_PROFILE" "$TARGET_ACCOUNT_ID"
      fi
    fi
  fi
}

# ─── Pod Identity, same account ──────────────────────────────────────────────
setup_pod_identity() {
  local pods_trust
  pods_trust=$(render_policy pod-identity-trust.json)

  header "Palette role in account $ACCOUNT_ID"
  setup_palette_role "$AWS_PROFILE" "$ACCOUNT_ID" "$DEPLOYER_ROLE_NAME" "$pods_trust" \
    "Spectro Cloud Palette role for EKS Pod Identity (${PERMISSION_PROFILE}); managed by setup-iam.sh"
  if [[ "$CFN_STACK_MODE" == "manual" ]]; then
    ensure_cfn_stack "$AWS_PROFILE" "$ACCOUNT_ID"
  fi

  header "Hubble role"
  ensure_role "$AWS_PROFILE" "$ACCOUNT_ID" "$HUBBLE_ROLE_NAME" "$pods_trust" \
    "Spectro Cloud Hubble service role for EKS Pod Identity; managed by setup-iam.sh"
  ensure_inline_policy "$AWS_PROFILE" "$ACCOUNT_ID" "$HUBBLE_ROLE_NAME" PaletteHubblePermissions hubble-permissions.json

  header "Identity service role"
  ensure_role "$AWS_PROFILE" "$ACCOUNT_ID" "$IDENTITY_ROLE_NAME" "$pods_trust" \
    "Spectro Cloud identity service role for EKS Pod Identity; managed by setup-iam.sh"
  ensure_inline_policy "$AWS_PROFILE" "$ACCOUNT_ID" "$IDENTITY_ROLE_NAME" PaletteIdentityPermissions identity-permissions.json

  if [[ -n "$CLUSTER_NAME" ]]; then
    setup_cluster "$HUBBLE_ROLE_ARN" "" "$IDENTITY_ROLE_ARN"
  else
    warn "CLUSTER_NAME is not set, so no Pod Identity associations were set up"
  fi
}

# ─── Pod Identity, cross-account ─────────────────────────────────────────────
# Roles are set up in the order the docs give, adjusted so that every role a
# trust policy names already exists: identity local, Hubble local, Palette
# target, Hubble target.
setup_pod_identity_cross_account() {
  local pods_trust palette_target_trust hubble_target_trust
  pods_trust=$(render_policy pod-identity-trust.json)
  palette_target_trust=$(render_policy palette-target-trust.json)
  hubble_target_trust=$(render_policy hubble-target-trust.json)

  header "Identity service local role in account $ACCOUNT_ID"
  ensure_role "$AWS_PROFILE" "$ACCOUNT_ID" "$IDENTITY_ROLE_NAME" "$pods_trust" \
    "Spectro Cloud identity service local role for cross-account EKS Pod Identity; managed by setup-iam.sh"
  ensure_inline_policy "$AWS_PROFILE" "$ACCOUNT_ID" "$IDENTITY_ROLE_NAME" PaletteIdentityPermissions identity-local-cross-permissions.json

  header "Hubble local role in account $ACCOUNT_ID"
  ensure_role "$AWS_PROFILE" "$ACCOUNT_ID" "$HUBBLE_ROLE_NAME" "$pods_trust" \
    "Spectro Cloud Hubble local role for cross-account EKS Pod Identity; managed by setup-iam.sh"
  ensure_inline_policy "$AWS_PROFILE" "$ACCOUNT_ID" "$HUBBLE_ROLE_NAME" PaletteHubbleCrossAccount hubble-local-cross-permissions.json

  header "Palette target role in account $TARGET_ACCOUNT_ID"
  setup_palette_role "$TARGET_AWS_PROFILE" "$TARGET_ACCOUNT_ID" "$TARGET_DEPLOYER_ROLE_NAME" \
    "$palette_target_trust" \
    "Spectro Cloud Palette target role for cross-account EKS Pod Identity (${PERMISSION_PROFILE}); managed by setup-iam.sh"
  if [[ "$CFN_STACK_MODE" == "manual" ]]; then
    ensure_cfn_stack "$TARGET_AWS_PROFILE" "$TARGET_ACCOUNT_ID"
  fi

  header "Hubble target role in account $TARGET_ACCOUNT_ID"
  if [[ "$HUBBLE_ROLE_NAME" != "spectro-hubble-identity" ]]; then
    info "The docs' Hubble target trust policy names role/spectro-hubble-identity; it is set to trust $HUBBLE_ROLE_NAME instead"
  fi
  ensure_role "$TARGET_AWS_PROFILE" "$TARGET_ACCOUNT_ID" "$TARGET_HUBBLE_ROLE_NAME" \
    "$hubble_target_trust" \
    "Spectro Cloud Hubble target role for cross-account EKS Pod Identity; managed by setup-iam.sh"
  ensure_inline_policy "$TARGET_AWS_PROFILE" "$TARGET_ACCOUNT_ID" "$TARGET_HUBBLE_ROLE_NAME" PaletteHubblePermissions hubble-target-permissions.json

  setup_cluster "$HUBBLE_ROLE_ARN" "$TARGET_HUBBLE_ARN" "$IDENTITY_ROLE_ARN"
}

case "$AUTH_MODE" in
  sts) setup_sts ;;
  pod-identity)
    if [[ "$POD_IDENTITY_CROSS_ACCOUNT" == true ]]; then
      setup_pod_identity_cross_account
    else
      setup_pod_identity
    fi
    ;;
esac

# ─── Summary ─────────────────────────────────────────────────────────────────
header "Summary"
if [[ "$CHANGES" -eq 0 ]]; then
  echo -e "\n${GREEN}${BOLD}  Everything already matches the docs. Nothing to change.${RESET}\n"
elif [[ "$APPLY" != true ]]; then
  echo -e "\n${CYAN}${BOLD}  $CHANGES change(s) planned. Review them, then re-run with --apply.${RESET}\n"
else
  echo -e "\n${GREEN}${BOLD}  $CHANGES change(s) made.${RESET}\n"
fi

PALETTE_ARN="$DEPLOYER_ROLE_ARN"
if [[ "$POD_IDENTITY_CROSS_ACCOUNT" == true ]]; then
  PALETTE_ARN="$TARGET_DEPLOYER_ARN"
fi
echo "  Next steps:"
if [[ "$AUTH_MODE" == "sts" ]]; then
  echo "  1. In Palette, add the AWS account with STS and enter this role ARN: $PALETTE_ARN"
else
  echo "  1. In Palette, add the AWS account with EKS Pod Identity and enter this role ARN: $PALETTE_ARN"
fi
echo "  2. Validate the setup: ./validate-iam.sh $AUTH_MODE"
if [[ "$CFN_STACK_MODE" == "manual" ]]; then
  echo "  3. Set manageCloudFormationStackManually.enabled: true in the Kubernetes layer of your cluster profiles"
fi
echo
