# Dockerfile — IT-Stack ZABBIX wrapper
# Module 19 | Category: infrastructure | Phase: 4
# Base image: zabbix/zabbix-server-pgsql:alpine-6.4-latest

FROM zabbix/zabbix-server-pgsql:alpine-6.4-latest

# Labels
LABEL org.opencontainers.image.title="it-stack-zabbix" \
      org.opencontainers.image.description="Zabbix infrastructure monitoring" \
      org.opencontainers.image.vendor="it-stack-dev" \
      org.opencontainers.image.licenses="Apache-2.0" \
      org.opencontainers.image.source="https://github.com/it-stack-dev/it-stack-zabbix"

# Copy custom configuration and scripts
COPY src/ /opt/it-stack/zabbix/
COPY docker/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD curl -f http://localhost/health || exit 1

ENTRYPOINT ["/entrypoint.sh"]
