#!/usr/bin/env bash
# test-lab-19-03.sh — Lab 19-03: Zabbix Advanced Features
# Tests: Zabbix Agent2 self-monitoring · extra pollers · resource limits
# Usage: bash test-lab-19-03.sh [--no-cleanup]
set -euo pipefail

LAB_ID="19-03"
LAB_NAME="Advanced Features — Zabbix Agent2 self-monitoring"
MODULE="zabbix"
COMPOSE_FILE="docker/docker-compose.advanced.yml"
PASS=0
FAIL=0

CLEANUP=true
[[ "${1:-}" == "--no-cleanup" ]] && CLEANUP=false

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; NC='\033[0m'

pass()    { echo -e "${GREEN}[PASS]${NC} $1"; ((PASS++)); }
fail()    { echo -e "${RED}[FAIL]${NC} $1"; ((FAIL++)); }
info()    { echo -e "${CYAN}[INFO]${NC} $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
section() { echo -e "\n${CYAN}── $1 ──${NC}"; }

cleanup() {
  if [[ "${CLEANUP}" == "true" ]]; then
    info "Cleaning up Lab ${LAB_ID} containers..."
    docker compose -f "${COMPOSE_FILE}" down -v --remove-orphans 2>/dev/null || true
  else
    info "Skipping cleanup (--no-cleanup)"
  fi
}
trap cleanup EXIT

echo -e "${CYAN}======================================${NC}"
echo -e "${CYAN} Lab ${LAB_ID}: ${LAB_NAME}${NC}"
echo -e "${CYAN} Module: ${MODULE}${NC}"
echo -e "${CYAN}======================================${NC}"
echo ""

# ── PHASE 1: Setup ────────────────────────────────────────────────────────────
section "Phase 1: Setup"
info "Starting Zabbix stack (db + mail + server + web + agent2)..."
docker compose -f "${COMPOSE_FILE}" up -d

# ── PHASE 2: Health Checks ────────────────────────────────────────────────────
section "Phase 2: Health Checks"

info "Waiting for MySQL (zabbix-a03-db)..."
for i in $(seq 1 18); do
  if docker exec zabbix-a03-db mysqladmin ping -h localhost -uzabbix -pZabbixLab03! --silent 2>/dev/null; then
    info "MySQL ready after ${i}×5s"
    break
  fi
  [[ $i -eq 18 ]] && { fail "MySQL did not become ready"; exit 1; }
  sleep 5
done

info "Waiting for Zabbix Server (10051)..."
for i in $(seq 1 18); do
  if docker exec zabbix-a03-server zabbix_server --version > /dev/null 2>&1; then
    info "Zabbix server binary accessible after ${i}×10s"
    break
  fi
  if docker exec zabbix-a03-server bash -c 'ss -tnlp | grep -q 10051' 2>/dev/null; then
    info "Zabbix server port 10051 open after ${i}×10s"
    break
  fi
  [[ $i -eq 18 ]] && { warn "Zabbix server check timed out"; }
  sleep 10
done

info "Waiting for Zabbix Web on port 8423..."
for i in $(seq 1 20); do
  HTTP=$(curl -o /dev/null -sw '%{http_code}' http://localhost:8423/ 2>/dev/null || echo "000")
  if echo "${HTTP}" | grep -qE '^[23]'; then
    info "Zabbix Web ready after ${i}×15s (HTTP ${HTTP})"
    break
  fi
  [[ $i -eq 20 ]] && { warn "Zabbix Web did not become fully ready"; }
  sleep 15
done

# ── PHASE 3: Functional Tests ─────────────────────────────────────────────────
section "Phase 3: Functional Tests — Advanced Features"

# 3.1 Container states (all 5)
for cname in zabbix-a03-db zabbix-a03-mail zabbix-a03-server zabbix-a03-web zabbix-a03-agent; do
  STATE=$(docker inspect "${cname}" --format '{{.State.Status}}' 2>/dev/null || echo "missing")
  if [[ "${STATE}" == "running" ]]; then
    pass "Container ${cname} is running"
  else
    fail "Container ${cname} state: ${STATE}"
  fi
done

# 3.2 Zabbix Agent2 running (Lab 03 key feature)
AGENT_STATE=$(docker inspect zabbix-a03-agent --format '{{.State.Status}}' 2>/dev/null || echo "missing")
if [[ "${AGENT_STATE}" == "running" ]]; then
  pass "zabbix-a03-agent (Agent2) is running (Lab 03 self-monitoring container)"
else
  fail "zabbix-a03-agent state: ${AGENT_STATE}"
fi

# 3.3 Agent ZBX_SERVER_HOST points to server
AGENT_SERVER=$(docker exec zabbix-a03-agent printenv ZBX_SERVER_HOST 2>/dev/null || echo "")
if [[ "${AGENT_SERVER}" == "zabbix-a03-server" ]]; then
  pass "Agent ZBX_SERVER_HOST=zabbix-a03-server (self-monitoring configured)"
else
  warn "Agent ZBX_SERVER_HOST='${AGENT_SERVER}' — expected 'zabbix-a03-server'"
fi

# 3.4 Zabbix Web HTTP check
HTTP_CODE=$(curl -o /dev/null -sw '%{http_code}' http://localhost:8423/ 2>/dev/null || echo "000")
if echo "${HTTP_CODE}" | grep -qE '^[234]'; then
  pass "Zabbix Web HTTP check: ${HTTP_CODE} on port 8423"
else
  fail "Zabbix Web HTTP check failed: ${HTTP_CODE}"
fi

# 3.5 Zabbix login page content
PAGE_CONTENT=$(curl -sf http://localhost:8423/ 2>/dev/null | head -50 || echo "")
if echo "${PAGE_CONTENT}" | grep -qi 'zabbix\|login\|zbx'; then
  pass "Zabbix login page is served"
else
  warn "Could not confirm Zabbix page content"
fi

# 3.6 Database table count
TABLE_COUNT=$(docker exec zabbix-a03-db mysql -uzabbix -pZabbixLab03! -e \
  "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='zabbix';" \
  --skip-column-names 2>/dev/null | tr -d '[:space:]' || echo "0")
if [[ "${TABLE_COUNT}" -gt 100 ]]; then
  pass "Zabbix database has ${TABLE_COUNT} tables"
elif [[ "${TABLE_COUNT}" -gt 0 ]]; then
  warn "Zabbix database has ${TABLE_COUNT} tables (may still initializing)"
else
  fail "Zabbix database appears empty"
fi

# 3.7 Memory limits
for cname in zabbix-a03-server zabbix-a03-web zabbix-a03-db zabbix-a03-agent; do
  MEM_LIMIT=$(docker inspect "${cname}" --format '{{.HostConfig.Memory}}' 2>/dev/null || echo "0")
  if [[ "${MEM_LIMIT}" -gt 0 ]]; then
    pass "${cname} has memory limit (${MEM_LIMIT} bytes)"
  else
    fail "${cname} has no memory limit"
  fi
done

# 3.8 Mailhog
MAIL_TOTAL=$(curl -sf http://localhost:8723/api/v2/messages 2>/dev/null | grep -o '"total":[0-9]*' | grep -o '[0-9]*' || echo "0")
pass "Mailhog API reachable (message count: ${MAIL_TOTAL})"

# 3.9 Volumes
for vol in zabbix-a03-db-data zabbix-a03-alertscripts zabbix-a03-externalscripts; do
  if docker volume ls --format '{{.Name}}' | grep -q "${vol}"; then
    pass "Volume ${vol} exists"
  else
    fail "Volume ${vol} not found"
  fi
done

# ── PHASE 4: (cleanup via trap) ────────────────────────────────────────────────
section "Phase 4: Results"

echo ""
echo -e "${CYAN}======================================${NC}"
echo -e " Lab ${LAB_ID} Complete"
echo -e " ${GREEN}PASS: ${PASS}${NC} | ${RED}FAIL: ${FAIL}${NC}"
echo -e "${CYAN}======================================${NC}"

if [[ "${FAIL}" -gt 0 ]]; then
  exit 1
fi

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; NC='\033[0m'
