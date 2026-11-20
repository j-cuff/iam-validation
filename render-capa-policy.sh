#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
CONFIG_FILE="${CONFIG_FILE:-${SCRIPT_DIR}/validate-iam.conf}"
TEMPLATE_FILE="${SCRIPT_DIR}/policies/capa-passrole-policy.template.json"

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

CAPA_ROLE_PATTERN="${ARN_PREFIX}:iam::${ACCOUNT_ID}:role/*.cluster-api-provider-aws.sigs.k8s.io"

jq --arg resource "$CAPA_ROLE_PATTERN" \
  '(.Statement[].Resource) = [$resource]' \
  "$TEMPLATE_FILE"
