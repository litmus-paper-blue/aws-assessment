# Unleash Live — AWS DevOps Assessment

## What This Is

This is a multi-region AWS infrastructure that deploys an identical compute stack to `us-east-1` and `eu-west-1`, secured by a single Cognito User Pool in `us-east-1`. The whole thing is written in Terraform, tested with a Python script, and wired up with a GitHub Actions pipeline.

The setup covers API Gateway, Lambda, DynamoDB, ECS Fargate, and a VPC — deployed twice, once per region, from one reusable module.

## Assessment Deliverables

The assessment asked for four things. Here's what was built and where to find each one.

### 1. IaC Code — Multi-Region Deployment

| Requirement | How It's Done | Where |
|---|---|---|
| Cognito User Pool + Client + test user | Dedicated Cognito module deployed in `us-east-1`. User created declaratively via `aws_cognito_user` resource — no local-exec, no CLI dependency | `modules/cognito/main.tf` |
| API Gateway with `/greet` and `/dispatch` | HTTP API with JWT authorizer pointing to the `us-east-1` Cognito pool | `modules/compute/main.tf` |
| DynamoDB table per region | `GreetingLogs` table with PAY_PER_REQUEST billing | `modules/compute/main.tf` |
| Lambda 1 (Greeter) — DynamoDB write + SNS publish | Writes to regional DynamoDB, publishes verification payload to Unleash Live SNS topic, returns 200 with region | `lambda/greeter/index.py` |
| Lambda 2 (Dispatcher) — ECS RunTask | Calls the ECS API to launch a Fargate task. Returns 500 if the task fails to launch — not a silent 200 | `lambda/dispatcher/index.py` |
| ECS Fargate — SNS publish from container | Task definition using `amazon/aws-cli`, logs the payload then runs `aws sns publish`, exits | `modules/compute/main.tf` |
| VPC with public subnets (no NAT) | Two public subnets, internet gateway, no NAT Gateway | `modules/compute/main.tf` |
| Multi-region via reusable module | One compute module, called twice with different provider aliases | `main.tf` |

### 2. Test Script — Automated Validation

| Requirement | How It's Done | Where |
|---|---|---|
| Authenticate with Cognito, get JWT | `boto3` Cognito `initiate_auth` with `USER_PASSWORD_AUTH` | `scripts/test_deployment.py` |
| Concurrent `/greet` calls in both regions | `asyncio.gather` with `aiohttp`, JWT in Authorization header | `scripts/test_deployment.py` |
| Concurrent `/dispatch` calls in both regions | Same pattern, triggers ECS tasks in both regions | `scripts/test_deployment.py` |
| Assert region matches, measure latency | Compares `region` in response payload, prints per-request latency and the geographic delta | `scripts/test_deployment.py` |

### 3. CI/CD Pipeline

| Requirement | How It's Done | Where |
|---|---|---|
| Lint/Validate | `terraform fmt`, `terraform validate`, `ruff` for Python | `.github/workflows/deploy.yml` |
| Security Scan | `tfsec` fails the build on HIGH/CRITICAL findings. `checkov` results uploaded as SARIF to GitHub Security tab | `.github/workflows/deploy.yml` |
| Plan | `terraform plan`, output posted as PR comment | `.github/workflows/deploy.yml` |
| Deploy | `terraform apply` only on merge to main, gated behind GitHub Environment approval | `.github/workflows/deploy.yml` |
| Test placeholder | Integration test step post-deploy | `.github/workflows/deploy.yml` |

### 4. README

You're reading it.

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                        us-east-1                                │
│  ┌──────────┐    ┌──────────────┐    ┌─────────────────────┐   │
│  │ Cognito   │    │ API Gateway  │───▶│ Lambda (Greeter)    │   │
│  │ User Pool │    │  /greet      │    │  → DynamoDB Write   │   │
│  │           │    │  /dispatch   │    │  → SNS Publish      │   │
│  └──────────┘    │  (JWT Auth)  │    └─────────────────────┘   │
│                  │              │───▶┌─────────────────────┐   │
│                  └──────────────┘    │ Lambda (Dispatcher)  │   │
│                                      │  → ECS RunTask       │   │
│  ┌──────────────┐                    └─────────────────────┘   │
│  │ ECS Fargate  │──▶ SNS Publish                               │
│  │ (Public VPC) │                                               │
│  └──────────────┘                                               │
├─────────────────────────────────────────────────────────────────┤
│                        eu-west-1                                │
│  (Identical compute stack — Cognito authorizer points back      │
│   to the us-east-1 pool for centralized auth)                   │
└─────────────────────────────────────────────────────────────────┘
```

Two regions, one auth source. A user authenticates against Cognito in `us-east-1`, gets a JWT, and that same token works against API Gateway in both regions. The JWT authorizer in `eu-west-1` simply references the `us-east-1` issuer URL — Cognito doesn't need to be deployed there.

## How the Multi-Region Setup Works

The core idea is straightforward: write the compute stack once, deploy it twice.

- **Root module** (`main.tf`) — Defines two AWS provider aliases (`us_east_1` and `eu_west_1`) and calls the compute module once per region.
- **Cognito module** (`modules/cognito/`) — Deployed in `us-east-1` only. Creates the User Pool, the App Client, and a test user.
- **Compute module** (`modules/compute/`) — API Gateway, both Lambdas, DynamoDB, VPC, ECS cluster, and the Fargate task definition. Takes `region` as a variable and names everything accordingly.

A note on `for_each`: Terraform does not support dynamic provider assignment in `for_each` module calls — the `providers` block must be static. So the two module blocks in `main.tf` are the correct pattern. Adding a third region means one more provider alias and one more module block.

## The Dry Run Toggle

Here's the thing — when you're building this kind of infrastructure, you don't want to fire off SNS messages to someone else's account every time you're testing. That verification topic belongs to Unleash Live, and blasting it with test payloads while you're still debugging IAM policies isn't exactly polite.

So I added a `dry_run` variable. It defaults to `false` — meaning the default deployment path performs the required SNS verification. When you're iterating locally, pass `-var="dry_run=true"` to skip SNS.

When `dry_run` is on:
- The **Greeter Lambda** writes to DynamoDB, returns a 200 with the region, but **skips the SNS publish**. Instead, it logs the full payload it would have sent to CloudWatch.
- The **ECS Fargate task** still gets launched by the Dispatcher (so you're testing the full ECS flow — cluster, task definition, VPC networking, IAM roles), but the container echoes the payload instead of publishing it.

Everything else works normally — Cognito auth, API Gateway routing, DynamoDB writes, ECS task scheduling. Full confidence that the wiring is correct, zero noise on the verification topic.

## Prerequisites

- AWS CLI v2, configured with credentials
- Terraform >= 1.5
- Python 3.10+

## Deploying

```bash
git clone https://github.com/litmus-paper-blue/aws-assessment.git
cd aws-assessment

cp terraform.tfvars.example terraform.tfvars
```

Open `terraform.tfvars` and set your values:

```hcl
test_email     = "your-email@example.com"
candidate_repo = "https://github.com/your-user/aws-assessment"
```

Then deploy:

```bash
terraform init
terraform plan
terraform apply
```

After apply, set the test user's password (one-time):

```bash
./scripts/create_test_user.sh
```

The Cognito user is created by Terraform declaratively. The password is set via this bootstrap script because Terraform's `aws_cognito_user` resource doesn't support setting passwords — this keeps the apply path clean and deterministic.

## Running the Tests

```bash
pip install -r scripts/requirements.txt
TEST_EMAIL="your-email@example.com" python3 scripts/test_deployment.py
```

It auto-detects API URLs and Cognito config from Terraform outputs when run from the project root. If you're running it from somewhere else:

```bash
export COGNITO_USER_POOL_ID="us-east-1_xxxxx"
export COGNITO_CLIENT_ID="xxxxxxxxxx"
export API_URL_US_EAST_1="https://xxxxx.execute-api.us-east-1.amazonaws.com"
export API_URL_EU_WEST_1="https://xxxxx.execute-api.eu-west-1.amazonaws.com"
export TEST_EMAIL="your-email@example.com"
export TEST_PASSWORD="TestPass1!"
```

The script:
1. Authenticates against the Cognito User Pool and retrieves a JWT.
2. Calls `GET /greet` in both regions concurrently, injecting the JWT as a Bearer token.
3. Calls `POST /dispatch` in both regions concurrently, triggering ECS Fargate tasks.
4. Asserts that the region in each response matches the region that was called, and prints the latency for each request to show the geographic difference.

## Tearing Down

Once the SNS payloads are confirmed:

```bash
terraform destroy
```

## CI/CD Pipeline

The GitHub Actions workflow (`.github/workflows/deploy.yml`) follows this flow:

**On Pull Request (against main):**
1. **Lint & Validate** — `terraform fmt -check`, `terraform validate`, `ruff` for Python.
2. **Security Scan** — `tfsec` fails the pipeline on HIGH and CRITICAL severity findings. `checkov` results are uploaded as SARIF to the GitHub Security tab so findings show up as reviewable annotations.
3. **Terraform Plan** — Runs the plan and posts the full output as a comment on the PR.

**On Merge to main:**
1. Steps 1–3 run again against the merged code.
2. **Deploy** — `terraform apply`, gated behind a GitHub Environment (`production`) that requires manual approval.
3. **Integration Tests** — Placeholder step for `test_deployment.py`. The structure and dependencies are wired; it just needs AWS credentials on the runner.

Nothing gets applied from a feature branch. PR → review the plan → merge → apply.

## Trade-offs and What I'd Change for Production

This is an assessment, so some choices were made for cost and simplicity that I'd handle differently in a production setting:

| Decision | Why (for this assessment) | What I'd do in prod |
|---|---|---|
| **Public subnets for Fargate** | Avoids NAT Gateway ($0.045/hr per region). The task only makes outbound API calls to SNS — it doesn't serve traffic | Private subnets + VPC endpoints for SNS and CloudWatch. More secure, but adds cost |
| **Centralized Cognito in one region** | Cognito is a regional service, and the JWT authorizer can reference a cross-region issuer URL. One pool means one source of truth for users | Add CloudFront or a global accelerator in front for lower-latency token issuance if user base is truly global |
| **No remote state backend** | Local state is simpler for a single-person assessment | S3 + DynamoDB state locking, one state file per environment |
| **No WAF on API Gateway** | Adds cost and complexity for a demo | WAF with rate limiting and geo-restrictions. API Gateway throttling at minimum |
| **`amazon/aws-cli` as ECS image** | Simple, pre-built, does the job. Pulls from Docker Hub on every run | Build a minimal custom image, push to ECR, pin the digest. Faster cold starts, no Docker Hub rate limit risk |
| **Two explicit module blocks** | Terraform doesn't support dynamic `providers` in `for_each`. Two blocks is the correct pattern | Same approach, potentially with Terragrunt if the region list grows beyond 3–4 |

## Cost Decisions

- **DynamoDB** — PAY_PER_REQUEST. No provisioned capacity sitting idle.
- **ECS Fargate** — 256 CPU / 512 MB (the minimum). Runs one CLI command and exits.
- **VPC** — Public subnets only. No NAT Gateway.
- **CloudWatch Logs** — 7-day retention across the board.
- **Container Insights** — Disabled on the ECS cluster.

## Security

- Every API route requires a valid Cognito JWT.
- Lambda execution roles are scoped to the specific resources they touch — one DynamoDB table, one SNS topic, one ECS task definition.
- The ECS security group allows outbound traffic only. No inbound rules.
- `terraform.tfvars` is in `.gitignore`.
- CI pipeline fails on HIGH/CRITICAL security findings from tfsec. Checkov results surface in the GitHub Security tab.

## Project Structure

```
.
├── main.tf                          # Root: providers, module calls, region wiring
├── variables.tf                     # Root variables (email, repo, dry_run, SNS ARN)
├── outputs.tf                       # Cognito IDs + API URLs (consumed by test script)
├── terraform.tfvars.example         # Copy to terraform.tfvars
├── modules/
│   ├── cognito/                     # Cognito User Pool + test user (us-east-1 only)
│   │   ├── main.tf
│   │   ├── variables.tf
│   │   └── outputs.tf
│   └── compute/                     # The per-region compute stack (deployed twice)
│       ├── main.tf                  # API GW, Lambda x2, DynamoDB, VPC, ECS Fargate
│       ├── variables.tf
│       └── outputs.tf
├── lambda/
│   ├── greeter/index.py             # /greet — DynamoDB write + SNS publish
│   └── dispatcher/index.py          # /dispatch — triggers ECS Fargate task
├── scripts/
│   ├── test_deployment.py           # Cognito auth + concurrent API tests + latency
│   ├── create_test_user.sh          # One-time: sets Cognito user password
│   └── requirements.txt             # boto3, aiohttp
└── .github/workflows/
    └── deploy.yml                   # PR: lint/scan/plan → Main: apply + test
```
