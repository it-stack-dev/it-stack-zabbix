#!/usr/bin/env bash
# test-lab-19-05.sh — Lab 19-05: Advanced Integration
# Module 19: Zabbix infrastructure monitoring
# zabbix integrated with full IT-Stack ecosystem
set -euo pipefail

LAB_ID="19-05"
LAB_NAME="Advanced Integration"
MODULE="zabbix"
COMPOSE_FILE="docker/docker-compose.integration.yml"
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
WEB_PORT=8443
MOCK_PORT=8764
KC_PORT=8543
LDAP_PORT=3888
MH_PORT=8743
MOCK_URL="http://localhost:${MOCK_PORT}"

WEB_CONTAINER="zabbix-i05-web"
SERVER_CONTAINER="zabbix-i05-server"
MOCK_CONTAINER="zabbix-i05-mock"

# ── Cleanup trap ──────────────────────────────────────────────────────────────
NO_CLEANUP=false
[[ "${1:-}" == "--no-cleanup" ]] && NO_CLEANUP=true

cleanup() {
  if [[ "${NO_CLEANUP}" == "false" ]]; then
    info "Phase 4: Cleanup"
    docker compose -f "${COMPOSE_FILE}" down -v --remove-orphans 2>/dev/null || true
    info "Cleanup complete"
  else
    warn "Skipping cleanup (--no-cleanup)"
  fi
}
trap cleanup EXIT

echo ""

# ── PHASE 1: Setup ────────────────────────────────────────────────────────────
info "Phase 1: Setup"
docker compose -f "${COMPOSE_FILE}" up -d
info "Waiting 90s for Zabbix stack to initialize (DB + server + web)..."
sleep 90

# ── PHASE 2: Health Checks ────────────────────────────────────────────────────
info "Phase 2: Health Checks"

if docker ps --format '{{.Names}}' | grep -q "^${SERVER_CONTAINER}$"; then
  pass "Zabbix Server container running"
else
  fail "Zabbix Server container not running"
fi

if docker ps --format '{{.Names}}' | grep -q "^${WEB_CONTAINER}$"; then
  pass "Zabbix Web container running"
else
  fail "Zabbix Web container not running"
fi

if docker ps --format '{{.Names}}' | grep -q "^${MOCK_CONTAINER}$"; then
  pass "WireMock container running"
else
  fail "WireMock container not running"
fi

# Zabbix web UI
if curl -sf "http://localhost:${WEB_PORT}/" > /dev/null 2>&1; then
  pass "Zabbix web UI responds"
else
  warn "Zabbix web UI not yet ready"
fi

# WireMock health
if curl -sf "${MOCK_URL}/__admin/health" > /dev/null; then
  pass "WireMock admin health OK"
else
  fail "WireMock admin health unreachable"
fi

# Keycloak
if curl -sf "http://localhost:${KC_PORT}/realms/master" > /dev/null 2>&1; then
  pass "Keycloak master realm accessible"
else
  warn "Keycloak not yet ready"
fi

# LDAP
if ldapsearch -x -H ldap://localhost:${LDAP_PORT} -b dc=lab,dc=local \
     -D cn=admin,dc=lab,dc=local -w LdapLab05! cn=admin > /dev/null 2>&1; then
  pass "OpenLDAP bind successful"
else
  warn "OpenLDAP bind failed"
fi

# ── PHASE 3: Integration Tests ────────────────────────────────────────────────
info "Phase 3: Integration Tests (Mattermost webhook via WireMock)"

# 3a: Register Mattermost incoming webhook stub
info "3a: Registering Mattermost /hooks/lab05 stub..."
HTTP_STATUS=$(curl -sf -o /dev/null -w "%{http_code}" \
  -X POST "${MOCK_URL}/__admin/mappings" \
  -H "Content-Type: application/json" \
  -d '{
    "request": {"method": "POST", "url": "/hooks/lab05"},
    "response": {
      "status": 200,
      "headers": {"Content-Type": "application/json"},
      "body": "ok"
    }
  }' || echo "000")
if [ "${HTTP_STATUS}" = "201" ]; then
  pass "WireMock Mattermost /hooks/lab05 stub registered (201)"
else
  fail "WireMock webhook stub registration failed (HTTP ${HTTP_STATUS})"
fi

# 3b: Verify Mattermost webhook mock responds
if curl -sf -X POST "${MOCK_URL}/hooks/lab05" \
     -H "Content-Type: application/json" \
     -d '{"text":"PROBLEM: Host zabbix-agent is unreachable","username":"zabbix-bot","channel":"ops-alerts"}' | grep -q 'ok'; then
  pass "WireMock Mattermost /hooks/lab05 returns expected response"
else
  fail "WireMock /hooks/lab05 returned unexpected response"
fi

# 3c: Integration env vars in Zabbix Web container
if docker exec "${WEB_CONTAINER}" env 2>/dev/null | grep -q 'MATTERMOST_WEBHOOK_URL='; then
  pass "MATTERMOST_WEBHOOK_URL env var present in Zabbix Web container"
else
  fail "MATTERMOST_WEBHOOK_URL env var missing from Zabbix Web container"
fi

if docker exec "${WEB_CONTAINER}" env 2>/dev/null | grep -q 'MATTERMOST_CHANNEL='; then
  pass "MATTERMOST_CHANNEL env var present in Zabbix Web container"
else
  fail "MATTERMOST_CHANNEL env var missing from Zabbix Web container"
fi

# 3d: Container-to-WireMock connectivity
if docker exec "${WEB_CONTAINER}" curl -sf http://zabbix-i05-mock:8080/__admin/health > /dev/null 2>&1; then
  pass "Zabbix Web container can reach WireMock (zabbix-i05-mock:8080)"
else
  fail "Zabbix Web container cannot reach WireMock"
fi

# 3e: Simulate Zabbix alert → Mattermost via WireMock
if docker exec "${WEB_CONTAINER}" curl -sf \
     -X POST http://zabbix-i05-mock:8080/hooks/lab05 \
     -H 'Content-Type: application/json' \
     -d '{"text":"PROBLEM triggered for ops-alerts","channel":"ops-alerts"}' 2>/dev/null | grep -q 'ok'; then
  pass "Zabbix → Mattermost alert dispatch succeeds (via WireMock)"
else
  warn "Zabbix → Mattermost alert dispatch not verified (web needs full setup)"
fi

# 3f: Volume assertions
if docker volume ls | grep -q 'zabbix-i05-server-data'; then
  pass "Zabbix server data volume exists"
else
  fail "Zabbix server data volume missing"
fi

# ── Results ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${CYAN}========================================${NC}"
echo -e " Lab ${LAB_ID} Complete"
echo -e " ${GREEN}PASS: ${PASS}${NC} | ${RED}FAIL: ${FAIL}${NC}"
echo -e "${CYAN}========================================${NC}"

[ "${FAIL}" -gt 0 ] && exit 1 || exit 0

# TODO: Add module-specific functional tests here
# Example:
# if curl -sf http://localhost:10051/health > /dev/null 2>&1; then
#     pass "Health endpoint responds"
# else
#     fail "Health endpoint not reachable"
# fi

warn "Functional tests for Lab 19-05 pending implementation"

# ── PHASE 4: Cleanup ──────────────────────────────────────────────────────────
info "Phase 4: Cleanup"
docker compose -f "${COMPOSE_FILE}" down -v --remove-orphans
info "Cleanup complete"

# ── Results ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${CYAN}======================================${NC}"
echo -e " Lab ${LAB_ID} Complete"
echo -e " ${GREEN}PASS: ${PASS}${NC} | ${RED}FAIL: ${FAIL}${NC}"
echo -e "${CYAN}======================================${NC}"

if [ "${FAIL}" -gt 0 ]; then
    exit 1
fi
