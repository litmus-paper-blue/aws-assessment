"""
Greeter Lambda - /greet endpoint
1. Writes a record to regional DynamoDB table
2. Publishes verification message to Unleash live SNS topic
3. Returns 200 with region name
"""

import json
import os
import uuid
from datetime import datetime, timezone

import boto3

dynamodb = boto3.resource("dynamodb")
sns = boto3.client("sns", region_name="us-east-1")  # SNS topic is in us-east-1

TABLE_NAME = os.environ["TABLE_NAME"]
VERIFICATION_SNS_ARN = os.environ["VERIFICATION_SNS_ARN"]
CANDIDATE_EMAIL = os.environ["CANDIDATE_EMAIL"]
CANDIDATE_REPO = os.environ["CANDIDATE_REPO"]
REGION = os.environ["REGION"]
DRY_RUN = os.environ.get("DRY_RUN", "false").lower() == "true"


def handler(event, context):
    try:
        # 1. Write to DynamoDB
        table = dynamodb.Table(TABLE_NAME)
        record = {
            "id": str(uuid.uuid4()),
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "region": REGION,
            "source": "greeter-lambda",
            "request_id": context.aws_request_id,
        }
        table.put_item(Item=record)

        # 2. Publish to SNS (skip in dry-run mode)
        sns_payload = {
            "email": CANDIDATE_EMAIL,
            "source": "Lambda",
            "region": REGION,
            "repo": CANDIDATE_REPO,
        }
        if DRY_RUN:
            print(f"[DRY_RUN] Would publish to {VERIFICATION_SNS_ARN}: {json.dumps(sns_payload)}")
        else:
            sns.publish(
                TopicArn=VERIFICATION_SNS_ARN,
                Message=json.dumps(sns_payload),
                Subject=f"Candidate Verification - Lambda - {REGION}",
            )

        # 3. Return success
        return {
            "statusCode": 200,
            "headers": {"Content-Type": "application/json"},
            "body": json.dumps(
                {
                    "message": "Greeting logged successfully",
                    "region": REGION,
                    "record_id": record["id"],
                    "sns_published": not DRY_RUN,
                    "dry_run": DRY_RUN,
                }
            ),
        }

    except Exception as e:
        print(f"Error: {e}")
        return {
            "statusCode": 500,
            "headers": {"Content-Type": "application/json"},
            "body": json.dumps({"error": str(e), "region": REGION}),
        }
