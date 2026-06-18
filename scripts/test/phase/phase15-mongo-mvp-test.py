# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    phase15-mongo-mvp-test.py                          :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/05/18 21:19:15 by dlesieur          #+#    #+#              #
#    Updated: 2026/05/18 21:19:15 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #

#!/usr/bin/env python3
"""
MongoDB MVP Integration Test Suite
Tests all 6 CRUD endpoints + user isolation + validation
"""

import os
import subprocess
import json
import sys
import secrets
import string
import time

GATEWAY = os.environ.get("BASE_URL", "http://localhost:8000")
ANON_KEY = os.environ.get("APIKEY") or os.environ.get("PUBLIC_APIKEY") or "public-anon-key"
COLLECTION = "tasks"
HEALTH_PATH = "/mongo/v1/health"
NOT_FOUND = "Not Found"

pass_count = 0
fail_count = 0


def log_info(msg):
    print(f"\033[0;34m[INFO]\033[0m {msg}")


def log_pass(msg):
    global pass_count
    pass_count += 1
    print(f"\033[0;32m[PASS]\033[0m {msg}")


def log_fail(msg):
    global fail_count
    fail_count += 1
    print(f"\033[0;31m[FAIL]\033[0m {msg}")


def probe(method, path, api_key="", jwt_token="", body=""):
    """Make HTTP request to gateway"""
    try:
        headers = ["-H", "Content-Type: application/json"]
        if api_key:
            headers.extend(["-H", f"apikey: {api_key}"])
        if jwt_token:
            headers.extend(["-H", f"Authorization: Bearer {jwt_token}"])
        
        cmd = ["curl", "-s", "-X", method, f"{GATEWAY}{path}"] + headers
        if body:
            cmd.extend(["-d", body])

        # subprocess.run with shell=False (default) and a list of args is safe
        # even when args contain user-controlled strings — argv is passed
        # directly to execve, no shell metacharacters are interpreted. The
        # semgrep rule below cannot prove that statically, so it is flagged
        # as a false positive in this codebase. The list-vs-string contract
        # is critical: never switch this call to a string + shell=True.
        # nosemgrep: python.lang.security.audit.dangerous-subprocess-use-tainted-env-args.dangerous-subprocess-use-tainted-env-args
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=5)
        return result.stdout
    except Exception as e:
        return json.dumps({"error": str(e)})


def random_email():
    """Generate random email"""
    return f"user_{secrets.token_hex(3)}@test.local"


def random_password():
    """Generate random password"""
    return f"P@ss-{secrets.token_hex(2)}-{secrets.randbelow(899)+100}"


print("\n" + "="*40)
print("MongoDB MVP Integration Test Suite")
print("="*40)
print(f"Gateway: {GATEWAY}")
print(f"API Key: {ANON_KEY}\n")

# P0: Auth and Gateway Security
print("=== P0: Auth and Gateway Security ===\n")

log_info("Test 1: Missing apikey returns error")
resp = probe("GET", HEALTH_PATH, "")
if "No API key" in resp or "missing_authorization" in resp or "Unauthorized" in resp:
    log_pass("Missing apikey correctly rejected")
else:
    log_fail(f"Expected auth error, got: {resp[:100]}")

log_info("Test 2: Invalid apikey returns error")
resp = probe("GET", HEALTH_PATH, "invalid-key-xyz")
if "Unauthorized" in resp or "Invalid" in resp or "No API key" in resp:
    log_pass("Invalid apikey correctly rejected")
else:
    log_fail(f"Expected auth error, got: {resp[:100]}")

log_info("Test 3: Valid apikey works")
resp = probe("GET", HEALTH_PATH, ANON_KEY)
if '"success":true' in resp or '"success": true' in resp or '"status":"ok"' in resp or '"status": "ok"' in resp:
    log_pass("Health check works with valid apikey")
else:
    log_fail(f"Health check failed: {resp}")

# P0: User Setup
print("\n=== P0: User Setup ===\n")

log_info("Test 4: Signup user A")
USER_A_EMAIL = random_email()
USER_A_PASSWORD = random_password()
signup_body = json.dumps({"email": USER_A_EMAIL, "password": USER_A_PASSWORD})
signup_resp = probe("POST", "/auth/v1/signup", ANON_KEY, "", signup_body)
try:
    user_a_data = json.loads(signup_resp)
    USER_A_ID = user_a_data.get("user", {}).get("id")
    if USER_A_ID:
        log_pass(f"User A signed up ({USER_A_EMAIL})")
    else:
        log_fail(f"Signup failed: {signup_resp}")
        sys.exit(1)
except Exception:
    log_fail(f"Signup failed: {signup_resp}")
    sys.exit(1)

time.sleep(0.5)  # Rate limit spacing

log_info("Test 5: Login user A")
login_body = json.dumps({"email": USER_A_EMAIL, "password": USER_A_PASSWORD})
login_resp = probe("POST", "/auth/v1/token?grant_type=password", ANON_KEY, "", login_body)
try:
    login_data = json.loads(login_resp)
    USER_A_JWT = login_data.get("access_token")
    if USER_A_JWT:
        log_pass("User A logged in")
    else:
        log_fail(f"Login failed: {login_resp}")
        sys.exit(1)
except Exception:
    log_fail(f"Login failed: {login_resp}")
    sys.exit(1)

time.sleep(0.5)  # Rate limit spacing

log_info("Test 6: Signup user B")
USER_B_EMAIL = random_email()
USER_B_PASSWORD = random_password()
signup_b_body = json.dumps({"email": USER_B_EMAIL, "password": USER_B_PASSWORD})
signup_b_resp = probe("POST", "/auth/v1/signup", ANON_KEY, "", signup_b_body)
try:
    user_b_data = json.loads(signup_b_resp)
    USER_B_ID = user_b_data.get("user", {}).get("id")
    if USER_B_ID:
        log_pass(f"User B signed up ({USER_B_EMAIL})")
    else:
        log_fail(f"Signup failed: {signup_b_resp}")
        sys.exit(1)
except Exception:
    log_fail(f"Signup failed: {signup_b_resp}")
    sys.exit(1)

time.sleep(0.5)  # Rate limit spacing

log_info("Test 7: Login user B")
login_b_body = json.dumps({"email": USER_B_EMAIL, "password": USER_B_PASSWORD})
login_b_resp = probe("POST", "/auth/v1/token?grant_type=password", ANON_KEY, "", login_b_body)
try:
    login_b_data = json.loads(login_b_resp)
    USER_B_JWT = login_b_data.get("access_token")
    if USER_B_JWT:
        log_pass("User B logged in")
    else:
        log_fail(f"Login failed: {login_b_resp}")
        sys.exit(1)
except Exception:
    log_fail(f"Login failed: {login_b_resp}")
    sys.exit(1)

time.sleep(0.5)  # Rate limit spacing

# P0: MongoDB CRUD
print("\n=== P0: MongoDB CRUD Operations ===\n")

log_info("Test 8: Create document as user A")
create_body = json.dumps({"data": {"title": "Task A", "status": "todo"}})
create_resp = probe("POST", f"/mongo/v1/collections/{COLLECTION}/documents", ANON_KEY, USER_A_JWT, create_body)
try:
    create_data = json.loads(create_resp)
    USER_A_DOC_ID = create_data.get("id")
    if USER_A_DOC_ID:
        log_pass(f"Created document (ID: {USER_A_DOC_ID[:8]}...)")
    else:
        log_fail(f"Create failed: {create_resp}")
except Exception:
    log_fail(f"Create failed: {create_resp}")

log_info("Test 9: List documents as user A")
list_resp = probe("GET", f"/mongo/v1/collections/{COLLECTION}/documents", ANON_KEY, USER_A_JWT)
try:
    list_data = json.loads(list_resp)
    count = len(list_data.get("data", []))
    if count >= 1:
        log_pass(f"Listed documents (count: {count})")
    else:
        log_fail(f"List returned no documents: {list_resp}")
except Exception:
    log_fail(f"List failed: {list_resp}")

log_info("Test 10: Get single document")
get_resp = probe("GET", f"/mongo/v1/collections/{COLLECTION}/documents/{USER_A_DOC_ID}", ANON_KEY, USER_A_JWT)
try:
    get_data = json.loads(get_resp)
    title = get_data.get("title") or get_data.get("data", {}).get("title")
    if title:
        log_pass(f"Retrieved document: {title}")
    else:
        log_fail(f"Get failed: {get_resp}")
except Exception:
    log_fail(f"Get failed: {get_resp}")

log_info("Test 11: Update document")
patch_body = json.dumps({"patch": {"status": "done"}})
patch_resp = probe("PATCH", f"/mongo/v1/collections/{COLLECTION}/documents/{USER_A_DOC_ID}", ANON_KEY, USER_A_JWT, patch_body)
try:
    patch_data = json.loads(patch_resp)
    status = patch_data.get("status") or patch_data.get("data", {}).get("status")
    if status == "done":
        log_pass(f"Updated document status to: {status}")
    else:
        log_fail(f"Update failed: {patch_resp}")
except Exception:
    log_fail(f"Update failed: {patch_resp}")

# P0: User Isolation
print("\n=== P0: User Isolation (Multi-tenant) ===\n")

log_info("Test 12: User B cannot GET user A's document")
isolation_resp = probe("GET", f"/mongo/v1/collections/{COLLECTION}/documents/{USER_A_DOC_ID}", ANON_KEY, USER_B_JWT)
try:
    isolation_data = json.loads(isolation_resp)
    status_code = isolation_data.get("statusCode") or isolation_data.get("status")
    error_code = isolation_data.get("error", {}).get("code") if isinstance(isolation_data.get("error"), dict) else isolation_data.get("error")
    if status_code == 404 or error_code in ("not_found", NOT_FOUND):
        log_pass("User B correctly denied (404)")
    else:
        log_fail(f"Isolation broken: {isolation_resp}")
except Exception:
    log_fail(f"Isolation check failed: {isolation_resp}")

log_info("Test 13: User B cannot PATCH user A's document")
patch_isolation_body = json.dumps({"patch": {"status": "hacked"}})
patch_isolation_resp = probe("PATCH", f"/mongo/v1/collections/{COLLECTION}/documents/{USER_A_DOC_ID}", ANON_KEY, USER_B_JWT, patch_isolation_body)
try:
    patch_data = json.loads(patch_isolation_resp)
    status_code = patch_data.get("statusCode") or patch_data.get("status")
    error_code = patch_data.get("error", {}).get("code") if isinstance(patch_data.get("error"), dict) else patch_data.get("error")
    if status_code == 404 or error_code in ("not_found", NOT_FOUND):
        log_pass("User B denied patch (404)")
    else:
        log_fail(f"Isolation broken: {patch_isolation_resp}")
except Exception:
    log_fail(f"Patch isolation check failed: {patch_isolation_resp}")

log_info("Test 14: User B cannot DELETE user A's document")
delete_isolation_resp = probe("DELETE", f"/mongo/v1/collections/{COLLECTION}/documents/{USER_A_DOC_ID}", ANON_KEY, USER_B_JWT)
try:
    delete_data = json.loads(delete_isolation_resp)
    status_code = delete_data.get("statusCode") or delete_data.get("status")
    error_code = delete_data.get("error", {}).get("code") if isinstance(delete_data.get("error"), dict) else delete_data.get("error")
    if status_code == 404 or error_code in ("not_found", NOT_FOUND):
        log_pass("User B denied delete (404)")
    else:
        log_fail(f"Isolation broken: {delete_isolation_resp}")
except Exception:
    log_fail(f"Delete isolation check failed: {delete_isolation_resp}")

# Cleanup
print("\n=== P0: Cleanup ===\n")

log_info("Test 15: Delete document as user A")
delete_resp = probe("DELETE", f"/mongo/v1/collections/{COLLECTION}/documents/{USER_A_DOC_ID}", ANON_KEY, USER_A_JWT)
try:
    delete_data = json.loads(delete_resp)
    if delete_data.get("deleted") or delete_data.get("success"):
        log_pass("Deleted document")
    else:
        log_fail(f"Delete failed: {delete_resp}")
except Exception:
    log_fail(f"Delete failed: {delete_resp}")

log_info("Test 16: Verify deletion (404)")
verify_resp = probe("GET", f"/mongo/v1/collections/{COLLECTION}/documents/{USER_A_DOC_ID}", ANON_KEY, USER_A_JWT)
try:
    verify_data = json.loads(verify_resp)
    status_code = verify_data.get("statusCode") or verify_data.get("status")
    error_code = verify_data.get("error", {}).get("code") if isinstance(verify_data.get("error"), dict) else verify_data.get("error")
    if status_code == 404 or error_code in ("not_found", NOT_FOUND):
        log_pass("Document correctly returns 404 after deletion")
    else:
        log_fail(f"Verify failed: {verify_resp}")
except Exception:
    log_fail(f"Verify failed: {verify_resp}")

# Validation
print("\n=== P1: Validation & Error Handling ===\n")

log_info("Test 17: Forbidden fields - cannot set owner_id")
forbidden_body = json.dumps({"data": {"title": "Hack", "owner_id": USER_B_ID}})
forbidden_resp = probe("POST", f"/mongo/v1/collections/{COLLECTION}/documents", ANON_KEY, USER_A_JWT, forbidden_body)
try:
    forbidden_data = json.loads(forbidden_resp)
    status_code = forbidden_data.get("statusCode")
    error_code = forbidden_data.get("error", {}).get("code") if isinstance(forbidden_data.get("error"), dict) else forbidden_data.get("error")
    if error_code in ("forbidden_fields", "Validation Error") or status_code in (400, 403):
        log_pass("Forbidden fields protection works")
    elif forbidden_data.get("owner_id") and forbidden_data.get("owner_id") != USER_B_ID:
        log_pass("Forbidden fields protection works (owner_id overridden by server)")
    else:
        log_fail(f"Security issue: {forbidden_resp}")
except Exception:
    log_fail(f"Forbidden fields check failed: {forbidden_resp}")

log_info("Test 18: Missing Authorization header")
no_auth_resp = probe("GET", f"/mongo/v1/collections/{COLLECTION}/documents", ANON_KEY, "")
try:
    no_auth_data = json.loads(no_auth_resp)
    status_code = no_auth_data.get("statusCode")
    error_code = no_auth_data.get("error", {}).get("code") if isinstance(no_auth_data.get("error"), dict) else no_auth_data.get("error")
    if error_code in ("missing_authorization", "Unauthorized") or status_code == 401:
        log_pass("Missing auth header rejected")
    else:
        log_fail(f"Auth check failed: {no_auth_resp}")
except Exception:
    log_fail(f"Auth check failed: {no_auth_resp}")

log_info("Test 19: Invalid ObjectId")
invalid_id_resp = probe("GET", f"/mongo/v1/collections/{COLLECTION}/documents/not-a-valid-id", ANON_KEY, USER_A_JWT)
try:
    invalid_data = json.loads(invalid_id_resp)
    status_code = invalid_data.get("statusCode")
    error_code = invalid_data.get("error", {}).get("code") if isinstance(invalid_data.get("error"), dict) else invalid_data.get("error")
    if error_code in ("invalid_id", "Validation Error") or status_code in (400, 422):
        log_pass("Invalid ObjectId rejected")
    else:
        log_fail(f"ID validation failed: {invalid_id_resp}")
except Exception:
    log_fail(f"ID validation failed: {invalid_id_resp}")

# Summary
print("\n" + "="*40)
print("Test Summary")
print("="*40)
print(f"\033[0;32mPassed: {pass_count}\033[0m")
print(f"\033[0;31mFailed: {fail_count}\033[0m")
total = pass_count + fail_count
if total > 0:
    print(f"Pass Rate: {100*pass_count//total}% ({pass_count}/{total})")

print()
if fail_count == 0:
    print("\033[0;32m✓ All tests passed!\033[0m")
    sys.exit(0)
else:
    print(f"\033[0;31m✗ {fail_count} tests failed.\033[0m")
    sys.exit(1)
