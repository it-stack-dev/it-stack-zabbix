#!/bin/bash
# entrypoint.sh — IT-Stack zabbix container entrypoint
set -euo pipefail

echo "Starting IT-Stack ZABBIX (Module 19)..."

# Source any environment overrides
if [ -f /opt/it-stack/zabbix/config.env ]; then
    # shellcheck source=/dev/null
    source /opt/it-stack/zabbix/config.env
fi

# Execute the upstream entrypoint or command
exec "$$@"
