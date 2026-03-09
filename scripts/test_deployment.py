#!/usr/bin/env python3
"""
Automated Test Script - Unleash live AWS Assessment
====================================================
1. Authenticates with Cognito to get a JWT
2. Concurrently calls /greet in both regions
3. Concurrently calls /dispatch in both regions
4. Asserts region correctness and measures latency

Usage:
    pip install boto3 aiohttp
    python test_deployment.py

Environment variables (or auto-detected from Terraform outputs):
    COGNITO_USER_POOL_ID  - Cognito User Pool ID
    COGNITO_CLIENT_ID     - Cognito App Client ID
    API_URL_US_EAST_1     - API Gateway URL in us-east-1
    API_URL_EU_WEST_1     - API Gateway URL in eu-west-1
    TEST_EMAIL            - Test user email
    TEST_PASSWORD         - Test user password (default: TestPass1!)
"""

import asyncio
import json
import os
import subprocess
import sys
import time

import aiohttp
import boto3


# ─── Configuration ───────────────────────────────────────────────────────────

def get_terraform_outputs() -> dict:
    """Parse Terraform outputs if env vars are not set."""
    try:
        result = subprocess.run(
            ["terraform", "output", "-json"],
            capture_output=True, text=True, check=True,
        )
        return json.loads(result.stdout)
    except (subprocess.CalledProcessError, FileNotFoundError, json.JSONDecodeError):
        return {}


def get_config() -> dict:
    """Build config from env vars, falling back to Terraform outputs."""
    tf = get_terraform_outputs()

    def val(env_key: str, tf_key: str, default: str = "") -> str:
        return os.environ.get(env_key) or tf.get(tf_key, {}).get("value", default)

    return {
        "user_pool_id": val("COGNITO_USER_POOL_ID", "cognito_user_pool_id"),
        "client_id":    val("COGNITO_CLIENT_ID", "cognito_client_id"),
        "api_us":       val("API_URL_US_EAST_1", "api_url_us_east_1"),
        "api_eu":       val("API_URL_EU_WEST_1", "api_url_eu_west_1"),
        "email":        val("TEST_EMAIL", "", os.environ.get("TEST_EMAIL", "")),
        "password":     os.environ.get("TEST_PASSWORD", "TestPass1!"),
    }


# ─── Cognito Authentication ─────────────────────────────────────────────────

def authenticate(config: dict) -> str:
    """Authenticate with Cognito using USER_PASSWORD_AUTH and return the ID token (JWT)."""
    client = boto3.client("cognito-idp", region_name="us-east-1")

    print(f"[AUTH] Authenticating {config['email']} against pool {config['user_pool_id']}...")

    response = client.initiate_auth(
        ClientId=config["client_id"],
        AuthFlow="USER_PASSWORD_AUTH",
        AuthParameters={
            "USERNAME": config["email"],
            "PASSWORD": config["password"],
        },
    )

    id_token = response["AuthenticationResult"]["IdToken"]
    print(f"[AUTH] ✓ JWT obtained (length: {len(id_token)})")
    return id_token


# ─── API Calls ───────────────────────────────────────────────────────────────

async def call_endpoint(
    session: aiohttp.ClientSession,
    url: str,
    method: str,
    token: str,
    expected_region: str,
    label: str,
) -> dict:
    """Call an API endpoint, measure latency, assert region."""
    headers = {"Authorization": f"Bearer {token}"}

    start = time.perf_counter()

    try:
        async with session.request(method, url, headers=headers) as resp:
            latency_ms = (time.perf_counter() - start) * 1000
            status = resp.status
            body = await resp.text()

            try:
                data = json.loads(body)
            except json.JSONDecodeError:
                data = {"raw": body}

            # Assert region
            actual_region = data.get("region", "UNKNOWN")
            region_match = actual_region == expected_region

            result = {
                "label": label,
                "status": status,
                "latency_ms": round(latency_ms, 2),
                "expected_region": expected_region,
                "actual_region": actual_region,
                "region_assert": "PASS" if region_match else "FAIL",
                "response": data,
            }

            return result

    except Exception as e:
        latency_ms = (time.perf_counter() - start) * 1000
        return {
            "label": label,
            "status": "ERROR",
            "latency_ms": round(latency_ms, 2),
            "error": str(e),
            "region_assert": "ERROR",
        }


async def run_tests(config: dict, token: str):
    """Execute all API tests concurrently."""
    api_us = config["api_us"].rstrip("/")
    api_eu = config["api_eu"].rstrip("/")

    async with aiohttp.ClientSession() as session:
        # ── Phase 1: /greet (GET) concurrently ──
        print("\n" + "=" * 60)
        print("PHASE 1: Concurrent /greet calls")
        print("=" * 60)

        greet_tasks = [
            call_endpoint(session, f"{api_us}/greet", "GET", token, "us-east-1", "greet:us-east-1"),
            call_endpoint(session, f"{api_eu}/greet", "GET", token, "eu-west-1", "greet:eu-west-1"),
        ]
        greet_results = await asyncio.gather(*greet_tasks)

        for r in greet_results:
            print_result(r)

        # ── Phase 2: /dispatch (POST) concurrently ──
        print("\n" + "=" * 60)
        print("PHASE 2: Concurrent /dispatch calls")
        print("=" * 60)

        dispatch_tasks = [
            call_endpoint(session, f"{api_us}/dispatch", "POST", token, "us-east-1", "dispatch:us-east-1"),
            call_endpoint(session, f"{api_eu}/dispatch", "POST", token, "eu-west-1", "dispatch:eu-west-1"),
        ]
        dispatch_results = await asyncio.gather(*dispatch_tasks)

        for r in dispatch_results:
            print_result(r)

        # ── Summary ──
        all_results = greet_results + dispatch_results
        print_summary(all_results)


# ─── Output Formatting ──────────────────────────────────────────────────────

def print_result(r: dict):
    """Print a single test result."""
    status_icon = "✓" if r["region_assert"] == "PASS" else "✗"
    print(f"\n  [{status_icon}] {r['label']}")
    print(f"      HTTP Status : {r.get('status', 'N/A')}")
    print(f"      Latency     : {r['latency_ms']} ms")
    print(f"      Region Assert: {r['region_assert']} "
          f"(expected={r.get('expected_region', '?')}, actual={r.get('actual_region', '?')})")

    if "error" in r:
        print(f"      Error       : {r['error']}")
    else:
        print(f"      Response    : {json.dumps(r.get('response', {}), indent=8)}")


def print_summary(results: list):
    """Print test summary."""
    print("\n" + "=" * 60)
    print("TEST SUMMARY")
    print("=" * 60)

    passed = sum(1 for r in results if r["region_assert"] == "PASS")
    failed = sum(1 for r in results if r["region_assert"] == "FAIL")
    errors = sum(1 for r in results if r["region_assert"] == "ERROR")

    print(f"  Passed : {passed}")
    print(f"  Failed : {failed}")
    print(f"  Errors : {errors}")
    print(f"  Total  : {len(results)}")

    # Latency comparison
    greet_results = [r for r in results if r["label"].startswith("greet")]
    if len(greet_results) == 2:
        print(f"\n  Latency Comparison (/greet):")
        for r in greet_results:
            print(f"    {r['label']}: {r['latency_ms']} ms")
        diff = abs(greet_results[0]["latency_ms"] - greet_results[1]["latency_ms"])
        print(f"    Δ (geographic difference): {round(diff, 2)} ms")

    print("=" * 60)

    if failed > 0 or errors > 0:
        print("RESULT: SOME TESTS FAILED")
        sys.exit(1)
    else:
        print("RESULT: ALL TESTS PASSED ✓")


# ─── Main ────────────────────────────────────────────────────────────────────

def main():
    print("Unleash live - AWS Assessment Test Runner")
    print("=" * 60)

    config = get_config()

    # Validate config
    missing = [k for k, v in config.items() if not v and k != "password"]
    if missing:
        print(f"[ERROR] Missing configuration: {', '.join(missing)}")
        print("Set via env vars or run from Terraform directory.")
        sys.exit(1)

    # Step 1: Authenticate
    token = authenticate(config)

    # Step 2-4: Run tests
    asyncio.run(run_tests(config, token))


if __name__ == "__main__":
    main()
