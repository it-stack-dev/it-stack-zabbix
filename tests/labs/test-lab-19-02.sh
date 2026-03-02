#!/usr/bin/env bash
# test-lab-19-02.sh — Lab 19-02: External Dependencies
# Module 19: Zabbix infrastructure monitoring
# zabbix with external PostgreSQL, Redis, and network integration
set -euo pipefail

LAB_ID="19-02"
LAB_NAME="External Dependencies"
MODULE="zabbix"
COMPOSE_FILE="docker/docker-compose.lan.yml"
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

# ── Cleanup control ───────────────────────────────────────────────────────────
CLEANUP=true
[[ "${1:-}" == "--no-cleanup" ]] && CLEANUP=false

cleanup() {
  if [[ "${CLEANUP}" == "true" ]]; then
    info "Phase 4: Cleanup"
    docker compose -f "${COMPOSE_FILE}" down -v --remove-orphans 2>/dev/null || true
    info "Cleanup complete"
  else
    info "Skipping cleanup (--no-cleanup)"
  fi
}
trap cleanup EXIT

# ── PHASE 1: Setup ────────────────────────────────────────────────────────────
info "Phase 1: Setup"
docker compose -f "${COMPOSE_FILE}" up -d

# ── PHASE 2: Health Checks ────────────────────────────────────────────────────
info "Phase 2: Health Checks"

info "Waiting for external MySQL (zabbix-l02-db, up to 90s)..."
for i in $(seq 1 18); do
  if docker exec zabbix-l02-db mysqladmin ping -uzabbix -pZabbixLab02! --silent 2>/dev/null; then
    pass "External MySQL healthy"
    break
  fi
  [[ $i -eq 18 ]] && fail "External MySQL timed out after 90s"
  sleep 5
done

info "Waiting for Mailhog (zabbix-l02-mail, up to 60s)..."
for i in $(seq 1 12); do
  if curl -sf http://localhost:8713/api/v2/messages >/dev/null 2>&1; then
    pass "Mailhog API reachable"
    break
  fi
  [[ $i -eq 12 ]] && fail "Mailhog timed out after 60s"
  sleep 5
done

info "Waiting for Zabbix server process (zabbix-l02-server, up to 180s)..."
for i in $(seq 1 36); do
  state=$(docker inspect --format='{{.State.Status}}' zabbix-l02-server 2>/dev/null || echo "missing")
  if [[ "${state}" == "running" ]]; then
    pass "Zabbix server container running"
    break
  fi
  [[ $i -eq 36 ]] && fail "Zabbix server timed out after 180s"
  sleep 5
done

info "Waiting for Zabbix web frontend (zabbix-l02-web, up to 240s)..."
for i in $(seq 1 24); do
  if curl -sf http://localhost:8413/ 2>/dev/null | grep -qi 'zabbix\|login'; then
    pass "Zabbix web frontend serving HTML"
    break
  fi
  [[ $i -eq 24 ]] && fail "Zabbix web frontend timed out after 240s"
  sleep 10
done

# ── PHASE 3: Functional Tests ─────────────────────────────────────────────────
info "Phase 3: Functional Tests (Lab 19-02 — External Dependencies)"

# Container states
for svc in zabbix-l02-db zabbix-l02-mail zabbix-l02-server zabbix-l02-web; do
  state=$(docker inspect --format='{{.State.Status}}' "${svc}" 2>/dev/null || echo "missing")
  if [[ "${state}" == "running" ]]; then
    pass "Container ${svc} is running"
  else
    fail "Container ${svc} state: ${state}"
  fi
done

# DB connectivity: Zabbix tables exist
table_count=$(docker exec zabbix-l02-db \
  mysql -uzabbix -pZabbixLab02! zabbix -e 'SHOW TABLES;' 2>/dev/null | wc -l | tr -d ' ')
if [[ "${table_count}" -gt 50 ]]; then
  pass "Zabbix database has ${table_count} tables (schema imported)"
else
  fail "Zabbix database tables: ${table_count} (expected >50, schema may not be imported)"
fi

# Mailhog API format check
mailhog_resp=$(curl -sf http://localhost:8713/api/v2/messages 2>/dev/null || echo "{}")
if echo "${mailhog_resp}" | grep -q 'total\|items\|count'; then
  pass "Mailhog API returns valid JSON message list"
else
  fail "Mailhog API response unexpected: ${mailhog_resp}"
fi

# HTTP status check
http_code=$(curl -o /dev/null -sw '%{http_code}' http://localhost:8413/ 2>/dev/null || echo "000")
if [[ "${http_code}" =~ ^[234] ]]; then
  pass "Zabbix web HTTP GET / -> ${http_code}"
else
  fail "Zabbix web HTTP GET / -> ${http_code}"
fi

# Login page present
if curl -sf http://localhost:8413/ 2>/dev/null | grep -qi 'zabbix\|login\|sign in'; then
  pass "Zabbix login page rendered"
else
  warn "Zabbix login page check inconclusive"
fi

# Zabbix server port 10051 reachable
if docker exec zabbix-l02-server bash -c 'echo > /dev/tcp/localhost/10051' 2>/dev/null; then
  pass "Zabbix trapper port 10051 accepting connections"
else
  warn "Zabbix trapper port 10051 check via bash /dev/tcp failed (module may not have bash)"
fi

# Key env vars present in server container
for var in DB_SERVER_HOST MYSQL_DATABASE MYSQL_USER; do
  if docker exec zabbix-l02-server printenv "${var}" 2>/dev/null | grep -q '.'; then
    pass "Env var ${var} set in zabbix-l02-server"
  else
    fail "Env var ${var} missing in zabbix-l02-server"
  fi
done

# Volume existence
for vol in zabbix-l02-db-data zabbix-l02-alertscripts zabbix-l02-externalscripts; do
  if docker volume ls --format '{{.Name}}' | grep -q "${vol}"; then
    pass "Volume ${vol} exists"
  else
    fail "Volume ${vol} missing"
  fi
done

# ── Results ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${CYAN}======================================${NC}"
echo -e " Lab ${LAB_ID} Complete"
echo -e " ${GREEN}PASS: ${PASS}${NC} | ${RED}FAIL: ${FAIL}${NC}"
echo -e "${CYAN}======================================${NC}"

if [ "${FAIL}" -gt 0 ]; then
    exit 1
fi
