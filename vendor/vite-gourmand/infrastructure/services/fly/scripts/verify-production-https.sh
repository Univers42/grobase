#!/bin/bash
set -euo pipefail

HOSTS="${HOSTS:-vite-gourmand.fr www.vite-gourmand.fr}"
PAGES="${PAGES:-/ /menus /contact /commande /mentions-legales /cgv}"
MIN_CERT_DAYS="${MIN_CERT_DAYS:-30}"

PASS_COUNT=0
FAIL_COUNT=0

pass() { echo "   [OK] $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo "   [FAIL] $1"; FAIL_COUNT=$((FAIL_COUNT + 1)); }

require_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "Required command missing: $1" >&2
        exit 1
    fi
}

check_dns() {
    local host="$1"
    local addresses
    addresses="$(getent ahosts "$host" 2>/dev/null | awk '{print $1}' | sort -u | tr '\n' ' ')"
    if [[ -z "$addresses" ]]; then
        fail "$host does not resolve in DNS"
        return
    fi
    pass "$host resolves to: $addresses"
}

check_certificate() {
    local host="$1"
    local output cert issuer subject not_after expiry_epoch now_epoch days_left

    output="$(openssl s_client -showcerts -servername "$host" -connect "$host:443" -verify_return_error </dev/null 2>&1 || true)"
    cert="$(printf '%s' "$output" | openssl x509 -noout -issuer -subject -enddate 2>/dev/null || true)"

    if [[ -z "$cert" ]]; then
        fail "$host does not present a readable TLS certificate"
        return
    fi

    if ! printf '%s' "$output" | grep -q "Verify return code: 0 (ok)"; then
        fail "$host certificate chain is not trusted by local OpenSSL"
        printf '%s\n' "$output" | grep -E "Verify return code|verify error" || true
        return
    fi

    issuer="$(printf '%s\n' "$cert" | sed -n 's/^issuer=//p')"
    subject="$(printf '%s\n' "$cert" | sed -n 's/^subject=//p')"
    not_after="$(printf '%s\n' "$cert" | sed -n 's/^notAfter=//p')"
    expiry_epoch="$(date -d "$not_after" +%s)"
    now_epoch="$(date -u +%s)"
    days_left="$(((expiry_epoch - now_epoch) / 86400))"

    if [[ "$days_left" -lt "$MIN_CERT_DAYS" ]]; then
        fail "$host certificate expires too soon: $days_left days left"
        return
    fi

    pass "$host certificate is trusted; issuer=$issuer; subject=$subject; expires in ${days_left}d"
}

check_http_redirect() {
    local host="$1"
    local headers status location
    headers="$(curl -sS --max-time 20 -o /dev/null -D - "http://$host/" 2>/dev/null || true)"
    status="$(printf '%s\n' "$headers" | awk 'NR==1 {print $2}')"
    location="$(printf '%s\n' "$headers" | awk 'tolower($1)=="location:" {print $2}' | tr -d '\r' | head -n 1)"

    if [[ "$status" =~ ^(301|308)$ && "$location" == https://* ]]; then
        pass "http://$host redirects to $location"
        return
    fi

    fail "http://$host does not permanently redirect to https:// (status=${status:-none}, location=${location:-none})"
}

check_hsts() {
    local host="$1"
    local headers hsts
    headers="$(curl -sS --max-time 20 -o /dev/null -D - "https://$host/" 2>/dev/null || true)"
    hsts="$(printf '%s\n' "$headers" | awk 'tolower($1)=="strict-transport-security:" {$1=""; sub(/^ /, ""); print}' | tr -d '\r' | head -n 1)"

    if [[ "$hsts" == *"max-age=31536000"* && "$hsts" == *"includeSubDomains"* && "$hsts" == *"preload"* ]]; then
        pass "https://$host sends HSTS: $hsts"
        return
    fi

    fail "https://$host missing required HSTS policy (found: ${hsts:-none})"
}

check_pages() {
    local host="$1"
    local page status
    for page in $PAGES; do
        status="$(curl -sS --max-time 20 -o /dev/null -w '%{http_code}' "https://$host$page" 2>/dev/null || true)"
        status="${status:-000}"
        if [[ "$status" =~ ^(200|204|301|302|307|308)$ ]]; then
            pass "https://$host$page responds with $status"
        else
            fail "https://$host$page failed HTTPS page check (status=$status)"
        fi
    done
}

require_command curl
require_command openssl
require_command date
require_command getent

echo "Production HTTPS Verification"
for host in $HOSTS; do
    echo ""
    echo "== $host =="
    check_dns "$host"
    check_certificate "$host"
    check_http_redirect "$host"
    check_hsts "$host"
    check_pages "$host"
done

echo ""
echo "Summary: $PASS_COUNT passed, $FAIL_COUNT failed"

if [[ "$FAIL_COUNT" -gt 0 ]]; then
    echo "Production HTTPS verification failed" >&2
    exit 1
fi

echo "Production HTTPS verification passed"