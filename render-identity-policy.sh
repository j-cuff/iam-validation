#!/usr/bin/env bash
# Renders policies/palette-identity-eks-policy.template.json for the
# same-account EKS Pod Identity setup: GetRole and PassRole are scoped to the
# Palette role (DEPLOYER_ROLE_NAME) in the configured partition and account.

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
CONFIG_FILE="${CONFIG_FILE:-${SCRIPT_DIR}/validate-iam.conf}"
TEMPLATE_FILE="${SCRIPT_DIR}/policies/palette-identity-eks-policy.template.json"

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "ERROR: Configuration file not found: $CONFIG_FILE" >&2
  exit 1
fi

# shellcheck source=/dev/null
source "$CONFIG_FILE"

if [[ -z "${AWS_PROFILE:-}" ]]; then
  echo "ERROR: AWS_PROFILE is not set in $CONFIG_FILE" >&2
  exit 1
fi
export AWS_PROFILE

PARTITION="${PARTITION:-aws}"
ACCOUNT_ID="${ACCOUNT_ID:-}"
DEPLOYER_ROLE_NAME="${DEPLOYER_ROLE_NAME:-SpectroCloudPaletteRole}"

case "$PARTITION" in
  aws)         ARN_PREFIX="arn:aws" ;;
  aws-us-gov)  ARN_PREFIX="arn:aws-us-gov" ;;
  aws-iso)     ARN_PREFIX="arn:aws-iso" ;;
  aws-iso-b)   ARN_PREFIX="arn:aws-iso-b" ;;
  *)
    echo "ERROR: Unknown PARTITION '$PARTITION'" >&2
    exit 1
    ;;
esac

if [[ -z "$ACCOUNT_ID" ]]; then
  ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
fi

PALETTE_ROLE_ARN="${ARN_PREFIX}:iam::${ACCOUNT_ID}:role/${DEPLOYER_ROLE_NAME}"

jq --arg arn "$PALETTE_ROLE_ARN" \
  '(.Statement[] | select(.Resource == ["${PALETTE_ROLE_ARN}"]) | .Resource) = [$arn]' \
  "$TEMPLATE_FILE"
