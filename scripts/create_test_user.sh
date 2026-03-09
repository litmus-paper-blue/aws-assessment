#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────
# One-time bootstrap: set a permanent password for the Cognito test user.
#
# The user itself is created by Terraform (aws_cognito_user resource).
# This script only sets the password, which Terraform cannot do
# declaratively.
#
# Usage:
#   ./scripts/create_test_user.sh
#
# Reads from Terraform outputs automatically.
# ─────────────────────────────────────────────────────────────────
set -euo pipefail

USER_POOL_ID="${COGNITO_USER_POOL_ID:-$(terraform output -raw cognito_user_pool_id 2>/dev/null)}"
USER_POOL_ID="${USER_POOL_ID:?Set COGNITO_USER_POOL_ID env var or run from Terraform directory}"
TEST_EMAIL="${TEST_EMAIL:?Set TEST_EMAIL env var}"
PASSWORD="${TEST_PASSWORD:-TestPass1!}"

echo "Setting password for ${TEST_EMAIL} in pool ${USER_POOL_ID}..."

aws cognito-idp admin-set-user-password \
  --user-pool-id "${USER_POOL_ID}" \
  --username "${TEST_EMAIL}" \
  --password "${PASSWORD}" \
  --permanent \
  --region us-east-1

echo "Done. User is ready for authentication."
