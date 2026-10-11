#!/usr/bin/env bash
# ==============================================================================
# Linux Application Health Check & Symptom Reporter
# Purpose: Validates systemd service status, port binding, and HTTP health endpoint.
# Note: This script reports observable symptoms to aid engineer troubleshooting;
#       it does NOT replace deep root cause analysis.
# ==============================================================================

set -uo pipefail

# Configuration
SERVICE_NAME="myapp"
EXPECTED_PORT="8000"
HEALTH_URL="http://127.0.0.1:${EXPECTED_PORT}/health"
TIMEOUT_SECS=3

# Colors for terminal output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

TOTAL_FAILURES=0

echo -e "${BLUE}====================================================${NC}"
echo -e "${BLUE}   Linux Application Health Check (DevOps POC)      ${NC}"
echo -e "${BLUE}====================================================${NC}"
echo "Timestamp: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
echo "Target Service : ${SERVICE_NAME}"
echo "Target Port    : ${EXPECTED_PORT}"
echo "Health Endpoint: ${HEALTH_URL}"
echo "----------------------------------------------------"

# ------------------------------------------------------------------------------
# Check 1: systemd service status
# ------------------------------------------------------------------------------
echo -n "[Check 1] Systemd Service State (${SERVICE_NAME}): "
if systemctl is-active --quiet "${SERVICE_NAME}" 2>/dev/null; then
    echo -e "${GREEN}[PASS] Service is ACTIVE${NC}"
else
    echo -e "${RED}[FAIL] Service is INACTIVE / FAILED${NC}"
    TOTAL_FAILURES=$((TOTAL_FAILURES + 1))
    echo -e "          ${YELLOW}--> Symptom: systemd reports service not running.${NC}"
    echo -e "          ${YELLOW}--> Recommended Next Step: Run 'systemctl status ${SERVICE_NAME}' or 'journalctl -u ${SERVICE_NAME} -n 20 --no-pager'${NC}"
fi

# ------------------------------------------------------------------------------
# Check 2: Port listening verification (via ss or netstat)
# ------------------------------------------------------------------------------
echo -n "[Check 2] Port Listening State (Port ${EXPECTED_PORT}): "
PORT_LISTENING=false

if command -v ss >/dev/null 2>&1; then
    if ss -tulpn 2>/dev/null | grep -q ":${EXPECTED_PORT} "; then
        PORT_LISTENING=true
    fi
elif command -v netstat >/dev/null 2>&1; then
    if netstat -tuln 2>/dev/null | grep -q ":${EXPECTED_PORT} "; then
        PORT_LISTENING=true
    fi
fi

if [ "$PORT_LISTENING" = true ]; then
    echo -e "${GREEN}[PASS] Port ${EXPECTED_PORT} is LISTENING${NC}"
else
    echo -e "${RED}[FAIL] Port ${EXPECTED_PORT} is NOT LISTENING${NC}"
    TOTAL_FAILURES=$((TOTAL_FAILURES + 1))
    echo -e "          ${YELLOW}--> Symptom: No process is bound to TCP port ${EXPECTED_PORT}.${NC}"
    echo -e "          ${YELLOW}--> Recommended Next Step: Check process table with 'ps aux | grep uvicorn' and verify startup port flags.${NC}"
fi

# ------------------------------------------------------------------------------
# Check 3: HTTP Endpoint Reachability & Health Status
# ------------------------------------------------------------------------------
echo -n "[Check 3] HTTP Health Endpoint (${HEALTH_URL}): "
HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout "${TIMEOUT_SECS}" "${HEALTH_URL}" 2>/dev/null || echo "000")

if [ "${HTTP_STATUS}" -eq 200 ]; then
    HTTP_BODY=$(curl -s --connect-timeout "${TIMEOUT_SECS}" "${HEALTH_URL}")
    echo -e "${GREEN}[PASS] HTTP 200 OK${NC}"
    echo "          Payload: ${HTTP_BODY}"
elif [ "${HTTP_STATUS}" -eq "000" ]; then
    echo -e "${RED}[FAIL] Connection Refused or Timeout (HTTP 000)${NC}"
    TOTAL_FAILURES=$((TOTAL_FAILURES + 1))
    echo -e "          ${YELLOW}--> Symptom: Cannot establish TCP handshake with endpoint.${NC}"
    echo -e "          ${YELLOW}--> Recommended Next Step: Verify if process crashed, port changed, or loopback firewall blocked.${NC}"
else
    echo -e "${RED}[FAIL] Unexpected HTTP Status: ${HTTP_STATUS}${NC}"
    TOTAL_FAILURES=$((TOTAL_FAILURES + 1))
    echo -e "          ${YELLOW}--> Symptom: Endpoint returned non-200 code (${HTTP_STATUS}).${NC}"
    echo -e "          ${YELLOW}--> Recommended Next Step: Check application logs for unhandled exceptions.${NC}"
fi

# ------------------------------------------------------------------------------
# Final Summary & Exit Code
# ------------------------------------------------------------------------------
echo "----------------------------------------------------"
if [ "${TOTAL_FAILURES}" -eq 0 ]; then
    echo -e "${GREEN}Overall Status: ALL HEALTH CHECKS PASSED (0 failures)${NC}"
    exit 0
else
    echo -e "${RED}Overall Status: CRITICAL - ${TOTAL_FAILURES} CHECK(S) FAILED${NC}"
    echo "Engineer Action Required: Use 'journalctl', 'ss', and 'ps' to conduct Root Cause Analysis."
    exit 1
fi
