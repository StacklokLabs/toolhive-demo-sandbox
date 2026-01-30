#!/bin/bash
set -e

# Validation script for ToolHive demo-in-a-box environment
# Reads demo-endpoints.json and validates all deployed services

ENDPOINTS_FILE="demo-endpoints.json"
FAILED_TESTS=0
PASSED_TESTS=0

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_pass() {
    echo -e "${GREEN}✓${NC} $1"
    PASSED_TESTS=$((PASSED_TESTS + 1))
}

log_fail() {
    echo -e "${RED}✗${NC} $1"
    FAILED_TESTS=$((FAILED_TESTS + 1))
}

log_warn() {
    echo -e "${YELLOW}⚠${NC} $1"
}

log_info() {
    echo "  $1"
}

# Helper: Retry a command with fixed delay
# Args: max_attempts, delay_seconds, command...
retry() {
    local max_attempts="$1" delay="$2"
    shift 2
    local attempt=1

    while [[ $attempt -le $max_attempts ]]; do
        if "$@"; then
            return 0
        fi
        if [[ $attempt -lt $max_attempts ]]; then
            log_info "Attempt $attempt/$max_attempts failed, retrying in ${delay}s..."
            sleep "$delay"
        fi
        attempt=$((attempt + 1))
    done
    return 1
}

# Helper: Build URL by joining base and path, handling trailing/leading slashes
build_url() {
    echo "${1%/}/${2#/}"
}

# Helper: Test HTTP/HTTPS endpoint (check only, no logging)
# Args: url, allow_insecure (true/false)
# Sets global LAST_HTTP_CODE for caller to use
_check_http_once() {
    local url="$1" allow_insecure="${2:-false}"
    local curl_opts="-s -o /dev/null -w %{http_code} --max-time 10 -L"

    [[ "$allow_insecure" == "true" ]] && curl_opts="$curl_opts -k"

    LAST_HTTP_CODE=$(curl $curl_opts "$url" 2>/dev/null || echo "000")
    [[ "$LAST_HTTP_CODE" =~ ^2 ]]
}

# Helper: Test HTTP/HTTPS endpoint with retry and log result
# Args: url, name, allow_insecure (true/false)
# Uses -L to follow redirects and verify final destination loads
test_http_endpoint() {
    local url="$1" name="$2" allow_insecure="${3:-false}"

    if retry 4 10 _check_http_once "$url" "$allow_insecure"; then
        log_pass "$name is responding (HTTP $LAST_HTTP_CODE)"
        [[ "$allow_insecure" == "true" ]] && log_info "Note: Using self-signed certificate"
        return 0
    else
        log_fail "$name returned HTTP $LAST_HTTP_CODE"
        return 1
    fi
}

# Helper: Check health endpoint (check only, no logging)
# Args: url
# Sets global LAST_HEALTH_STATUS for caller to use
_check_health_once() {
    local url="$1"
    local response

    response=$(curl -s --max-time 10 "$url" 2>/dev/null || echo "")
    LAST_HEALTH_STATUS=$(echo "$response" | jq -r '.status // empty' 2>/dev/null || echo "")
    [[ "$LAST_HEALTH_STATUS" =~ ^(healthy|ok)$ ]]
}

# Helper: Check health endpoint with retry and log result
# Args: url, name
# Accepts "healthy" or "ok" as valid statuses
check_health_endpoint() {
    local url="$1" name="$2"

    if retry 4 10 _check_health_once "$url"; then
        log_pass "$name health check passed (status: $LAST_HEALTH_STATUS)"
        return 0
    else
        log_fail "$name health check failed (expected status=healthy or ok, got: '$LAST_HEALTH_STATUS')"
        return 1
    fi
}

# Check for required binaries
echo "Checking required tools..."
MISSING_TOOLS=""
for tool in curl jq; do
    if ! command -v "$tool" > /dev/null 2>&1; then
        MISSING_TOOLS="$MISSING_TOOLS $tool"
    fi
done

if [[ -n "$MISSING_TOOLS" ]]; then
    log_fail "Missing required tools:$MISSING_TOOLS"
    exit 1
fi
log_pass "Required tools available (curl, jq)"

# Check for thv (optional but recommended for MCP tests)
THV_AVAILABLE=false
if command -v thv > /dev/null 2>&1; then
    THV_AVAILABLE=true
    log_pass "ToolHive CLI (thv) available"
else
    log_warn "ToolHive CLI (thv) not available - MCP endpoint tests will be limited"
fi

# Check if endpoints file exists
if [[ ! -f "$ENDPOINTS_FILE" ]]; then
    log_fail "Endpoints file '$ENDPOINTS_FILE' not found. Run bootstrap.sh first."
    exit 1
fi
log_pass "Found $ENDPOINTS_FILE"

# Parse JSON and validate
echo ""
echo "Validating endpoints..."
echo ""

ENDPOINT_COUNT=$(jq -r '.endpoints | length' "$ENDPOINTS_FILE")

for i in $(seq 0 $((ENDPOINT_COUNT - 1))); do
    # Extract all fields in a single jq call using tab-separated values
    IFS=$'\t' read -r NAME URL TYPE EXPECT_CERT_ERROR HEALTHCHECK_PATH TEST_WITH_THV REGISTRY_API_PATH < <(
        jq -r ".endpoints[$i] | [.name, .url, .type, (.expect_cert_error // false), (.healthcheck_path // \"\"), (.test_with_thv // false), (.registry_api_path // \"\")] | @tsv" "$ENDPOINTS_FILE"
    )

    echo "[$((i+1))/$ENDPOINT_COUNT] Testing $NAME"
    log_info "URL: $URL"
    log_info "Type: $TYPE"

    case "$TYPE" in
        http|https)
            # Determine test URL
            if [[ -n "$HEALTHCHECK_PATH" ]] && [[ ! "$URL" =~ $HEALTHCHECK_PATH$ ]]; then
                TEST_URL=$(build_url "$URL" "$HEALTHCHECK_PATH")
            else
                TEST_URL="$URL"
            fi

            # HTTPS: allow insecure if expecting cert errors
            if [[ "$TYPE" == "https" ]]; then
                test_http_endpoint "$TEST_URL" "$NAME" "$EXPECT_CERT_ERROR" || true
            else
                test_http_endpoint "$TEST_URL" "$NAME" "false" || true
            fi
            ;;

        registry)
            # Check health endpoint
            HEALTH_URL=$(build_url "$URL" "$HEALTHCHECK_PATH")
            check_health_endpoint "$HEALTH_URL" "$NAME" || true

            # Check if registry is populated
            if [[ -n "$REGISTRY_API_PATH" ]]; then
                REGISTRY_URL=$(build_url "$URL" "$REGISTRY_API_PATH")
                SERVER_COUNT=$(curl -s --max-time 10 "$REGISTRY_URL" 2>/dev/null | jq -r '.metadata.count // 0' 2>/dev/null || echo "0")

                if [[ -n "$SERVER_COUNT" ]] && [[ "$SERVER_COUNT" -gt 0 ]] 2>/dev/null; then
                    log_pass "$NAME is populated ($SERVER_COUNT servers)"
                else
                    log_warn "$NAME appears empty (server count: $SERVER_COUNT)"
                fi
            fi
            ;;

        mcp)
            # Check health endpoint if available
            if [[ -n "$HEALTHCHECK_PATH" ]]; then
                # Extract base URL (protocol + hostname)
                BASE_URL=$(echo "$URL" | sed -E 's|(https?://[^/]+).*|\1|')
                HEALTH_URL=$(build_url "$BASE_URL" "$HEALTHCHECK_PATH")
                check_health_endpoint "$HEALTH_URL" "$NAME" || true
            fi

            # If thv is available and test_with_thv is true, test with thv
            if [[ "$THV_AVAILABLE" == "true" ]] && [[ "$TEST_WITH_THV" == "true" ]]; then
                log_info "Testing with thv mcp list tools..."
                if thv mcp list tools --server "$URL" > /dev/null 2>&1; then
                    log_pass "$NAME passed thv MCP test"
                else
                    log_warn "$NAME failed thv MCP test (endpoint may not be fully initialized)"
                fi
            fi
            ;;

        *)
            log_warn "Unknown endpoint type: $TYPE"
            ;;
    esac

    echo ""
done

# Summary
echo "================================"
echo "Validation Summary"
echo "================================"
echo -e "${GREEN}Passed: $PASSED_TESTS${NC}"
echo -e "${RED}Failed: $FAILED_TESTS${NC}"
echo ""

if [[ $FAILED_TESTS -gt 0 ]]; then
    echo "❌ Validation FAILED"
    exit 1
else
    echo "✅ All validations PASSED"
    exit 0
fi
