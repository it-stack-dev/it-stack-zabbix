# Architecture — IT-Stack ZABBIX

## Overview

Zabbix monitors all IT-Stack servers and services, sending alerts to Mattermost and integrating with Graylog for log-based triggers.

## Role in IT-Stack

- **Category:** infrastructure
- **Phase:** 4
- **Server:** lab-comm1 (10.0.50.14)
- **Ports:** 10051 (Server), 3000 (Web UI)

## Dependencies

| Dependency | Type | Required For |
|-----------|------|--------------|
| FreeIPA | Identity | User directory |
| Keycloak | SSO | Authentication |
| PostgreSQL | Database | Data persistence |
| Redis | Cache | Sessions/queues |
| Traefik | Proxy | HTTPS routing |

## Data Flow

```
User → Traefik (HTTPS) → zabbix → PostgreSQL (data)
                       ↗ Keycloak (auth)
                       ↗ Redis (sessions)
```

## Security

- All traffic over TLS via Traefik
- Authentication delegated to Keycloak OIDC
- Database credentials via Ansible Vault
- Logs shipped to Graylog
