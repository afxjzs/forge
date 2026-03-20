#!/usr/bin/env bash
# Smoke test template for forge projects
# Copy to your project as scripts/smoke-test.sh and customize
#
# Exit 0 = all passed, Exit 1 = failures detected
#
# Usage: smoke-test.sh <base-url>

BASE_URL="${1:?Usage: smoke-test.sh <base-url>}"
FAILURES=0

pass() { echo "  ✓ $1"; }
fail() { echo "  ✗ $1"; FAILURES=$((FAILURES + 1)); }

check_status() {
    local name="$1" url="$2" expected="${3:-200}"
    local status
    status=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "$url") || status="000"
    if [[ "$status" == "$expected" ]]; then
        pass "$name (HTTP $status)"
    else
        fail "$name — expected $expected, got $status"
    fi
}

check_json() {
    local name="$1" url="$2" field="$3"
    local response
    response=$(curl -s --max-time 10 "$url") || { fail "$name — connection failed"; return; }
    if echo "$response" | python3 -c "import sys,json; d=json.load(sys.stdin); assert '$field' in d" 2>/dev/null; then
        pass "$name"
    else
        fail "$name — missing field '$field'"
    fi
}

echo "Smoke tests: $BASE_URL"
echo ""

# --- ADD YOUR TESTS BELOW ---

# check_status "Health endpoint" "$BASE_URL/api/health"
# check_json "Health returns status" "$BASE_URL/api/health" "status"
# check_status "Homepage loads" "$BASE_URL/"

# --- END TESTS ---

echo ""
if [[ $FAILURES -gt 0 ]]; then
    echo "FAILED: $FAILURES test(s) failed"
    exit 1
else
    echo "PASSED: all tests passed"
    exit 0
fi
