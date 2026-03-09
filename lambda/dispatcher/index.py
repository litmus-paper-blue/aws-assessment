"""
Dispatcher Lambda - /dispatch endpoint
Triggers an ECS Fargate task that publishes to the Unleash live SNS topic.
"""

import json
import os

import boto3

ecs = boto3.client("ecs")

ECS_CLUSTER_ARN = os.environ["ECS_CLUSTER_ARN"]
TASK_DEFINITION_ARN = os.environ["TASK_DEFINITION_ARN"]
SUBNET_IDS = os.environ["SUBNET_IDS"].split(",")
SECURITY_GROUP_ID = os.environ["SECURITY_GROUP_ID"]
REGION = os.environ["REGION"]


def handler(event, context):
    try:
        response = ecs.run_task(
            cluster=ECS_CLUSTER_ARN,
            taskDefinition=TASK_DEFINITION_ARN,
            launchType="FARGATE",
            count=1,
            networkConfiguration={
                "awsvpcConfiguration": {
                    "subnets": SUBNET_IDS,
                    "securityGroups": [SECURITY_GROUP_ID],
                    "assignPublicIp": "ENABLED",
                }
            },
        )

        tasks = response.get("tasks", [])
        task_arns = [t["taskArn"] for t in tasks]
        failures = response.get("failures", [])

        if failures:
            print(f"ECS RunTask failures: {failures}")
            return {
                "statusCode": 500,
                "headers": {"Content-Type": "application/json"},
                "body": json.dumps(
                    {
                        "error": "ECS task failed to launch",
                        "region": REGION,
                        "failures": [f["reason"] for f in failures],
                    }
                ),
            }

        return {
            "statusCode": 200,
            "headers": {"Content-Type": "application/json"},
            "body": json.dumps(
                {
                    "message": "ECS Fargate task dispatched",
                    "region": REGION,
                    "task_arns": task_arns,
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
