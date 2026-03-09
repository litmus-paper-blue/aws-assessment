#!/usr/bin/env bash
###############################################################################
# cleanup.sh - Delete all AWS resources created by the Terraform project
#
# Use this when Terraform state is lost and you can't run terraform destroy.
# Resources are identified by naming convention: unleash-dev-{region}
###############################################################################
set -euo pipefail

REGIONS=("us-east-1" "eu-west-1")
ENV="dev"
COGNITO_REGION="us-east-1"
COGNITO_POOL_NAME="unleash-live-${ENV}"
TEST_USER_EMAIL="ogonna.devops@gmail.com"

safe() {
  echo "  -> $*"
  if ! "$@" 2>&1; then
    echo "  [WARN] Command failed (resource may already be deleted), continuing..."
  fi
}

echo "========================================="
echo " AWS Resource Cleanup"
echo "========================================="

for REGION in "${REGIONS[@]}"; do
  PREFIX="unleash-${ENV}-${REGION}"
  echo ""
  echo "========================================="
  echo " Region: ${REGION} (prefix: ${PREFIX})"
  echo "========================================="

  # ── API Gateway ──────────────────────────────────────────────────────────
  echo ""
  echo "[1/7] Deleting API Gateway: ${PREFIX}-api"

  API_ID=$(aws apigatewayv2 get-apis --region "${REGION}" \
    --query "Items[?Name=='${PREFIX}-api'].ApiId | [0]" --output text 2>/dev/null || echo "None")

  if [[ "${API_ID}" != "None" && -n "${API_ID}" ]]; then
    echo "  Found API ID: ${API_ID}"

    safe aws apigatewayv2 delete-stage --region "${REGION}" \
      --api-id "${API_ID}" --stage-name '$default'

    ROUTE_IDS=$(aws apigatewayv2 get-routes --region "${REGION}" \
      --api-id "${API_ID}" --query "Items[].RouteId" --output text 2>/dev/null || echo "")
    for ROUTE_ID in ${ROUTE_IDS}; do
      safe aws apigatewayv2 delete-route --region "${REGION}" \
        --api-id "${API_ID}" --route-id "${ROUTE_ID}"
    done

    INTEGRATION_IDS=$(aws apigatewayv2 get-integrations --region "${REGION}" \
      --api-id "${API_ID}" --query "Items[].IntegrationId" --output text 2>/dev/null || echo "")
    for INT_ID in ${INTEGRATION_IDS}; do
      safe aws apigatewayv2 delete-integration --region "${REGION}" \
        --api-id "${API_ID}" --integration-id "${INT_ID}"
    done

    AUTH_IDS=$(aws apigatewayv2 get-authorizers --region "${REGION}" \
      --api-id "${API_ID}" --query "Items[].AuthorizerId" --output text 2>/dev/null || echo "")
    for AUTH_ID in ${AUTH_IDS}; do
      safe aws apigatewayv2 delete-authorizer --region "${REGION}" \
        --api-id "${API_ID}" --authorizer-id "${AUTH_ID}"
    done

    safe aws apigatewayv2 delete-api --region "${REGION}" --api-id "${API_ID}"
  else
    echo "  Not found, skipping."
  fi

  # ── Lambda ───────────────────────────────────────────────────────────────
  echo ""
  echo "[2/7] Deleting Lambda functions"

  for FUNC_NAME in "${PREFIX}-greeter" "${PREFIX}-dispatcher"; do
    safe aws lambda remove-permission --region "${REGION}" \
      --function-name "${FUNC_NAME}" --statement-id "AllowAPIGateway"
    safe aws lambda delete-function --region "${REGION}" \
      --function-name "${FUNC_NAME}"
  done

  # ── DynamoDB ─────────────────────────────────────────────────────────────
  echo ""
  echo "[3/7] Deleting DynamoDB table: ${PREFIX}-GreetingLogs"
  safe aws dynamodb delete-table --region "${REGION}" \
    --table-name "${PREFIX}-GreetingLogs"

  # ── ECS ──────────────────────────────────────────────────────────────────
  echo ""
  echo "[4/7] Deleting ECS resources"

  CLUSTER_NAME="${PREFIX}-cluster"
  TASK_FAMILY="${PREFIX}-verification"

  RUNNING_TASKS=$(aws ecs list-tasks --region "${REGION}" \
    --cluster "${CLUSTER_NAME}" --desired-status RUNNING \
    --query "taskArns[]" --output text 2>/dev/null || echo "")
  for TASK_ARN in ${RUNNING_TASKS}; do
    safe aws ecs stop-task --region "${REGION}" \
      --cluster "${CLUSTER_NAME}" --task "${TASK_ARN}" --reason "Cleanup"
  done

  TD_ARNS=$(aws ecs list-task-definitions --region "${REGION}" \
    --family-prefix "${TASK_FAMILY}" --query "taskDefinitionArns[]" \
    --output text 2>/dev/null || echo "")
  for TD_ARN in ${TD_ARNS}; do
    safe aws ecs deregister-task-definition --region "${REGION}" \
      --task-definition "${TD_ARN}"
    safe aws ecs delete-task-definitions --region "${REGION}" \
      --task-definitions "${TD_ARN}"
  done

  safe aws ecs delete-cluster --region "${REGION}" --cluster "${CLUSTER_NAME}"

  # ── CloudWatch ───────────────────────────────────────────────────────────
  echo ""
  echo "[5/7] Deleting CloudWatch log groups"

  safe aws logs delete-log-group --region "${REGION}" \
    --log-group-name "/aws/apigateway/${PREFIX}-api"
  safe aws logs delete-log-group --region "${REGION}" \
    --log-group-name "/ecs/${PREFIX}-verification"

  # ── IAM ──────────────────────────────────────────────────────────────────
  echo ""
  echo "[6/7] Deleting IAM roles and policies"

  LAMBDA_ROLE="${PREFIX}-lambda-exec"
  safe aws iam delete-role-policy --role-name "${LAMBDA_ROLE}" --policy-name "${PREFIX}-greeter"
  safe aws iam delete-role-policy --role-name "${LAMBDA_ROLE}" --policy-name "${PREFIX}-dispatcher"
  safe aws iam detach-role-policy --role-name "${LAMBDA_ROLE}" \
    --policy-arn "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
  safe aws iam delete-role --role-name "${LAMBDA_ROLE}"

  ECS_EXEC_ROLE="${PREFIX}-ecs-task-exec"
  safe aws iam detach-role-policy --role-name "${ECS_EXEC_ROLE}" \
    --policy-arn "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
  safe aws iam delete-role --role-name "${ECS_EXEC_ROLE}"

  ECS_TASK_ROLE="${PREFIX}-ecs-task-role"
  safe aws iam delete-role-policy --role-name "${ECS_TASK_ROLE}" --policy-name "${PREFIX}-ecs-sns"
  safe aws iam delete-role --role-name "${ECS_TASK_ROLE}"

  # ── VPC ──────────────────────────────────────────────────────────────────
  echo ""
  echo "[7/7] Deleting VPC resources"

  VPC_ID=$(aws ec2 describe-vpcs --region "${REGION}" \
    --filters "Name=tag:Name,Values=${PREFIX}-vpc" \
    --query "Vpcs[0].VpcId" --output text 2>/dev/null || echo "None")

  if [[ "${VPC_ID}" != "None" && -n "${VPC_ID}" ]]; then
    echo "  Found VPC: ${VPC_ID}"

    SG_IDS=$(aws ec2 describe-security-groups --region "${REGION}" \
      --filters "Name=vpc-id,Values=${VPC_ID}" \
      --query "SecurityGroups[?GroupName!='default'].GroupId" \
      --output text 2>/dev/null || echo "")
    for SG_ID in ${SG_IDS}; do
      safe aws ec2 delete-security-group --region "${REGION}" --group-id "${SG_ID}"
    done

    RT_IDS=$(aws ec2 describe-route-tables --region "${REGION}" \
      --filters "Name=vpc-id,Values=${VPC_ID}" \
      --query "RouteTables[?Associations[0].Main!=\`true\`].RouteTableId" \
      --output text 2>/dev/null || echo "")
    for RT_ID in ${RT_IDS}; do
      ASSOC_IDS=$(aws ec2 describe-route-tables --region "${REGION}" \
        --route-table-ids "${RT_ID}" \
        --query "RouteTables[0].Associations[?!Main].RouteTableAssociationId" \
        --output text 2>/dev/null || echo "")
      for ASSOC_ID in ${ASSOC_IDS}; do
        safe aws ec2 disassociate-route-table --region "${REGION}" \
          --association-id "${ASSOC_ID}"
      done
      safe aws ec2 delete-route-table --region "${REGION}" --route-table-id "${RT_ID}"
    done

    SUBNET_IDS=$(aws ec2 describe-subnets --region "${REGION}" \
      --filters "Name=vpc-id,Values=${VPC_ID}" \
      --query "Subnets[].SubnetId" --output text 2>/dev/null || echo "")
    for SUBNET_ID in ${SUBNET_IDS}; do
      safe aws ec2 delete-subnet --region "${REGION}" --subnet-id "${SUBNET_ID}"
    done

    IGW_IDS=$(aws ec2 describe-internet-gateways --region "${REGION}" \
      --filters "Name=attachment.vpc-id,Values=${VPC_ID}" \
      --query "InternetGateways[].InternetGatewayId" --output text 2>/dev/null || echo "")
    for IGW_ID in ${IGW_IDS}; do
      safe aws ec2 detach-internet-gateway --region "${REGION}" \
        --internet-gateway-id "${IGW_ID}" --vpc-id "${VPC_ID}"
      safe aws ec2 delete-internet-gateway --region "${REGION}" \
        --internet-gateway-id "${IGW_ID}"
    done

    safe aws ec2 delete-vpc --region "${REGION}" --vpc-id "${VPC_ID}"
  else
    echo "  VPC not found, skipping."
  fi

  echo ""
  echo "  Region ${REGION} cleanup complete."
done

###############################################################################
# Cognito (us-east-1 only)
###############################################################################
echo ""
echo "========================================="
echo " Cognito Cleanup (${COGNITO_REGION})"
echo "========================================="

USER_POOL_ID=$(aws cognito-idp list-user-pools --region "${COGNITO_REGION}" \
  --max-results 60 \
  --query "UserPools[?Name=='${COGNITO_POOL_NAME}'].Id | [0]" \
  --output text 2>/dev/null || echo "None")

if [[ "${USER_POOL_ID}" != "None" && -n "${USER_POOL_ID}" ]]; then
  echo "  Found User Pool: ${USER_POOL_ID}"

  safe aws cognito-idp admin-delete-user --region "${COGNITO_REGION}" \
    --user-pool-id "${USER_POOL_ID}" --username "${TEST_USER_EMAIL}"

  CLIENT_IDS=$(aws cognito-idp list-user-pool-clients --region "${COGNITO_REGION}" \
    --user-pool-id "${USER_POOL_ID}" \
    --query "UserPoolClients[].ClientId" --output text 2>/dev/null || echo "")
  for CLIENT_ID in ${CLIENT_IDS}; do
    safe aws cognito-idp delete-user-pool-client --region "${COGNITO_REGION}" \
      --user-pool-id "${USER_POOL_ID}" --client-id "${CLIENT_ID}"
  done

  safe aws cognito-idp delete-user-pool --region "${COGNITO_REGION}" \
    --user-pool-id "${USER_POOL_ID}"
else
  echo "  User pool '${COGNITO_POOL_NAME}' not found, skipping."
fi

echo ""
echo "========================================="
echo " Cleanup complete!"
echo "========================================="
