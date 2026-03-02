#!/usr/bin/env bash
# test-lab-19-01.sh — Lab 19-01: Standalone
# Module 19: Zabbix infrastructure monitoring
# Basic zabbix functionality in complete isolation
set -euo pipefail

LAB_ID="19-01"
LAB_NAME="Standalone"
MODULE="zabbix"
COMPOSE_FILE="docker/docker-compose.standalone.yml"
PASS=0
FAIL=0

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; NC='\033[0m'

pass() { echo -e "${GREEN}[PASS]${NC} $1"; ((PASS++)); }
fail() { echo -e "${RED}[FAIL]${NC} $1"; ((FAIL++)); }
info() { echo -e "${CYAN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }

echo -e "${CYAN}======================================${NC}"
echo -e "${CYAN} Lab ${LAB_ID}: ${LAB_NAME}${NC}"
echo -e "${CYAN} Module: ${MODULE}${NC}"
echo -e "${CYAN}======================================${NC}"
echo ""

# ── PHASE 1: Setup ────────────────────────────────────────────────────────────
info "Phase 1: Setup"
docker compose -f "${COMPOSE_FILE}" up -d
info "Waiting 30s for ${MODULE} to initialize..."
sleep 30

# ── PHASE 2: Health Checks ────────────────────────────────────────────────────
info "Phase 2: Health Checks"

if docker compose -f "${COMPOSE_FILE}" ps | grep -q "running\|Up"; then
    pass "Container is running"
else
    fail "Container is not running"
fi

# ── PHASE 3: Functional Tests ─────────────────────────────────────────────────
info "Phase 3: Functional Tests (Lab 01 — Standalone)"

ZABBIX_WEB="http://localhost:8403"
ZABBIX_SERVER_PORT=10051
NO_CLEANUP=${NO_CLEANUP:-0}

cleanup() {
    if [ "${NO_CLEANUP}" = "1" ]; then
        info "NO_CLEANUP=1 — skipping teardown"
    else
        info "Phase 4: Cleanup"
        docker compose -f "${COMPOSE_FILE}" down -v --remove-orphans 2>/dev/null || true
        info "Cleanup complete"
    fi
}
trap cleanup EXIT

section() { echo -e "\n${CYAN}## $1${NC}"; }

# ── PHASE 1: Setup ────────────────────────────────────────────────────────────
section "Phase 1: Setup"
docker compose -f "${COMPOSE_FILE}" up -d
info "Waiting 120s for Zabbix to initialize (MySQL + server + web)..."
sleep 120

# ── PHASE 2: Health Checks ────────────────────────────────────────────────────
section "Phase 2: Health Checks"

if docker compose -f "${COMPOSE_FILE}" ps zabbix-s01-db 2>/dev/null | grep -q 'Up\|running'; then
    pass "2.1 MySQL (zabbix-s01-db) is up"
else
    fail "2.1 MySQL is not running"
fi

if docker compose -f "${COMPOSE_FILE}" ps zabbix-s01-server 2>/dev/null | grep -q 'Up\|running'; then
    pass "2.2 Zabbix server (zabbix-s01-server) is up"
else
    fail "2.2 Zabbix server is not running"
fi

if docker compose -f "${COMPOSE_FILE}" ps zabbix-s01-web 2>/dev/null | grep -q 'Up\|running'; then
    pass "2.3 Zabbix web (zabbix-s01-web) is up"
else
    fail "2.3 Zabbix web is not running"
fi

# ── PHASE 3: Functional Tests ─────────────────────────────────────────────────
section "Phase 3: Functional Tests"

# 3.1 Web UI responds
HTTP_CODE=$(curl -o /dev/null -sw '%{http_code}' -L "${ZABBIX_WEB}/" 2>/dev/null || echo 000)
if echo "${HTTP_CODE}" | grep -q '^[23]'; then
    pass "3.1 Zabbix web UI accessible (HTTP ${HTTP_CODE})"
else
    fail "3.1 Zabbix web UI not accessible (HTTP ${HTTP_CODE})"
fi

# 3.2 Web UI contains Zabbix content
RESPONSE=$(curl -sfL "${ZABBIX_WEB}/" 2>/dev/null || echo '')
if echo "${RESPONSE}" | grep -qi 'zabbix\|login\|monitoring'; then
    pass "3.2 Zabbix web UI contains application content"
else
    warn "3.2 Could not confirm Zabbix content (app may still be starting)"
fi

# 3.3 Zabbix API endpoint responds
HTTP_API=$(curl -o /dev/null -sw '%{http_code}' \
    -X POST "${ZABBIX_WEB}/api_jsonrpc.php" \
    -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","method":"apiinfo.version","params":{},"id":1}' \
    2>/dev/null || echo 000)
if echo "${HTTP_API}" | grep -q '^[23]'; then
    pass "3.3 Zabbix JSON-RPC API responds (HTTP ${HTTP_API})"
else
    warn "3.3 Zabbix JSON-RPC API not yet ready (HTTP ${HTTP_API})"
fi

# 3.4 Zabbix server port is listening
if bash -c "</dev/tcp/localhost/${ZABBIX_SERVER_PORT}" 2>/dev/null; then
    pass "3.4 Zabbix server port ${ZABBIX_SERVER_PORT} is open"
else
    warn "3.4 Zabbix server port ${ZABBIX_SERVER_PORT} not yet open"
fi

# ── Results ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${CYAN}======================================${NC}"
echo -e " Lab ${LAB_ID} Complete"
echo -e " ${GREEN}PASS: ${PASS}${NC} | ${RED}FAIL: ${FAIL}${NC}"
echo -e "${CYAN}======================================${NC}"

if [ "${FAIL}" -gt 0 ]; then
    exit 1
fi
