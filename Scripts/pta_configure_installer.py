#!/usr/bin/env python3
"""
Drive PTA installer.war wizard API via curl subprocess.
Uses curl instead of Python urllib to avoid Rocky Linux 9 crypto-policy
TLS handshake conflicts with Tomcat's SSL configuration.

Usage: python3 pta_configure_installer.py <vault_ip> <vault_pass> <pvwa_host> <root_pass> [admin_user] [timezone]
"""
import json
import subprocess
import sys
import time

VAULT_IP         = sys.argv[1] if len(sys.argv) > 1 else "192.168.100.20"
VAULT_ADMIN_PASS = sys.argv[2] if len(sys.argv) > 2 else "Cyberark1"
PVWA_HOST        = sys.argv[3] if len(sys.argv) > 3 else "comp01.cyberark.lab"
ROOT_PASS        = sys.argv[4] if len(sys.argv) > 4 else "Cyberark!Local2024"
VAULT_ADMIN_USER = sys.argv[5] if len(sys.argv) > 5 else "Administrator"
VAULT_TZ         = sys.argv[6] if len(sys.argv) > 6 else "UTC"
BASE_URL         = "https://localhost:8443/installer"

SENTINEL = "__HTTP_STATUS__"


def curl_req(method, url, data=None, content_type=None, headers=None, timeout=60):
    cmd = [
        "curl", "-sk", "-m", str(timeout),
        "-X", method,
        "-w", f"\n{SENTINEL}%{{http_code}}",
    ]
    if data is not None:
        cmd += ["--data", data]
    if content_type:
        cmd += ["-H", f"Content-Type: {content_type}"]
    for k, v in (headers or {}).items():
        cmd += ["-H", f"{k}: {v}"]
    cmd.append(url)

    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout + 10)
    except subprocess.TimeoutExpired:
        raise RuntimeError(f"curl timed out after {timeout}s for {method} {url}")

    if result.returncode != 0:
        raise RuntimeError(f"curl exit {result.returncode}: {result.stderr[:200]}")

    raw = result.stdout
    if SENTINEL in raw:
        body, status_str = raw.rsplit(SENTINEL, 1)
        try:
            status = int(status_str.strip())
        except ValueError:
            status = 0
    else:
        body, status = raw, 0

    return status, body.strip()


print("=== PTA Installer API Configuration ===")
print(f"  Vault: {VAULT_IP}  PVWA: {PVWA_HOST}")
print(f"  Using curl to reach {BASE_URL}")

# Pre-check: can we reach installer.war at all?
print("\n[0] Pre-check: installer.war reachability (15s timeout)...")
try:
    status, body = curl_req("GET", f"{BASE_URL}/", timeout=15)
    print(f"    GET /installer/ -> HTTP {status}")
    if status == 0:
        print("    ERROR: curl returned HTTP 0 -- installer.war not reachable")
        sys.exit(1)
except RuntimeError as e:
    print(f"    ERROR: {e}")
    sys.exit(1)

# Step 1: get auth token
print("\n[1] Getting auth token from installer.war...")
form_data = f"username=root&password={ROOT_PASS}"
status, body = curl_req("POST", f"{BASE_URL}/api/getauthtoken",
                        data=form_data,
                        content_type="application/x-www-form-urlencoded",
                        timeout=30)
print(f"    HTTP {status}: {body[:120]}")
if status != 200:
    print(f"    ERROR: auth failed (HTTP {status}). Check root password or wizard state.")
    sys.exit(1)

try:
    token = json.loads(body)["Authorization"]
except (json.JSONDecodeError, KeyError) as e:
    print(f"    ERROR: cannot parse auth token: {e}. Body: {body[:200]}")
    sys.exit(1)

print(f"    Token: {token[:40]}...")
auth_hdrs = {"Authorization": f"Bearer {token}"}

# Step 1.5: check current wizard state; reset if already SUCCESS
print("\n[1.5] Checking current wizard state...")
status, body = curl_req("GET", f"{BASE_URL}/api/installation/", headers=auth_hdrs)
print(f"    HTTP {status}: {body[:200]}")
try:
    current_state = json.loads(body).get("status", "UNKNOWN")
except Exception:
    current_state = "UNKNOWN"
print(f"    State: {current_state}")

if current_state in ("SUCCESS", "FAILED"):
    # SUCCESS: wizard ran during pta_installer.sh with placeholder defaults — reset to re-POST correct values.
    # FAILED: previous run partially failed — wizard blocks re-POST with HTTP 403 WBS0705E unless reset.
    print(f"    Wizard state is {current_state} -- resetting via DELETE...")
    status, body = curl_req("DELETE", f"{BASE_URL}/api/installation/", headers=auth_hdrs)
    print(f"    DELETE -> HTTP {status}: {body[:120]}")
    time.sleep(5)
    status, body = curl_req("GET", f"{BASE_URL}/api/installation/", headers=auth_hdrs)
    print(f"    State after reset: {body[:200]}")
elif current_state in ("RUNNING",):
    print("    Wizard is running -- waiting for it to finish before overwriting...")
    for _ in range(30):
        time.sleep(10)
        status, body = curl_req("GET", f"{BASE_URL}/api/installation/", headers=auth_hdrs)
        try:
            current_state = json.loads(body).get("status", "UNKNOWN")
        except Exception:
            current_state = "UNKNOWN"
        print(f"    State: {current_state}")
        if current_state != "RUNNING":
            break

# Step 2: POST wizard configuration with correct vault / PVWA values
print("\n[2] Posting wizard configuration...")
payload = {
    "vault": {
        "ip": VAULT_IP,
        "port": "1858",
        "timezone": VAULT_TZ,
        "adminUser": VAULT_ADMIN_USER,
        "adminPassword": VAULT_ADMIN_PASS,
        "daysActivity": "180"
    },
    "pvwa": {
        "connectionMethod": "https",
        "host": PVWA_HOST,
        "port": "443",
        "appContext": "PasswordVault"
    },
    "syslogInbound": {
        "inbound_514": "tls",
        "inbound_11514": "tcp,tls"
    },
    "skipRestart": "true"
}
status, body = curl_req("POST", f"{BASE_URL}/api/installation/",
                        data=json.dumps(payload),
                        content_type="application/json",
                        headers=auth_hdrs,
                        timeout=30)
print(f"    HTTP {status}: {body[:240]}")
if status not in (200, 201, 204):
    print(f"    ERROR: wizard POST failed (HTTP {status}).")
    sys.exit(1)

# Step 3: poll for SUCCESS (max 10 min)
print("\n[3] Polling wizard status (max 10 min)...")
for i in range(60):
    time.sleep(10)
    status, body = curl_req("GET", f"{BASE_URL}/api/installation/", headers=auth_hdrs)
    try:
        wiz_status = json.loads(body).get("status", "UNKNOWN")
    except Exception:
        wiz_status = f"PARSE_ERROR: {body[:80]}"
    print(f"    [{i+1:02d}] {wiz_status}")
    if wiz_status == "SUCCESS":
        print("\n=== Wizard completed successfully ===")
        sys.exit(0)
    elif wiz_status == "RUNNING":
        continue
    elif wiz_status == "FAILED":
        print(f"\nWizard entered FAILED state. Full response:\n{body[:400]}")
        print("Re-run this script -- it will DELETE the FAILED state and retry.")
        sys.exit(1)
    else:
        print(f"\nUnexpected status '{wiz_status}'. Full response:\n{body[:400]}")
        sys.exit(1)

print("\nERROR: Wizard timed out after 10 minutes")
sys.exit(1)
