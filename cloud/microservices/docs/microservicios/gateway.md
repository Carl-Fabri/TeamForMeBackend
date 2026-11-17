# API Gateway (nginx)

**Código:** `gateway/default.conf.template`, `gateway/Dockerfile` · **Puerto:** 8080

## Responsabilidad
Único punto de entrada público. Desacopla al cliente de la topología interna: el frontend solo
conoce `/api`, no cuántos microservicios hay ni dónde corren.

## Tabla de enrutamiento
Las reglas regex se evalúan **en orden** y gana la primera que coincide:

| # | Patrón | Destino |
|---|---|---|
| 1 | `/internal` en cualquier parte | **404** (nunca se expone) |
| 2 | `^/api/events/{id}/teams$` | MS.Teams |
| 3 | `^/api/teams/{id}/applications$` | MS.Applications |
| 4 | `^/api/users/{id}/notifications$` | MS.Notifications |
| 5 | `^/api/events` | MS.Events |
| 6 | `^/api/teams` | MS.Teams |
| 7 | `^/api/applications` | MS.Applications |
| 8 | `^/api/users` | MS.Users |
| — | `/health` | 200 (sonda del gateway) |
| — | `= /api/{servicio}/_info` | `/info` de la réplica que atendió (coincidencia exacta, prioridad sobre las regex) |
| — | `/` | Frontend Angular SSR |

El prefijo `/api` se elimina (`rewrite ^/api/(.*)$ /$1 break;`) antes de reenviar.

## Configuración por entorno
La imagen oficial de nginx procesa `/etc/nginx/templates/*.template` con `envsubst` al arrancar:

| Variable | Docker Compose | Azure Container Apps |
|---|---|---|
| `EVENTS_UPSTREAM` | `http://ms-events:8080` | `http://ms-events.internal.<defaultDomain>` |
| `TEAMS_UPSTREAM` | `http://ms-teams:8080` | `http://ms-teams.internal.<defaultDomain>` |
| `FRONTEND_UPSTREAM` | `http://frontend:4000` | `http://frontend.internal.<defaultDomain>` |
| … | … | … |

No se sobrescribe la cabecera `Host`: en Container Apps el proxy Envoy enruta por `Host`, así que
debe llegar el nombre del upstream (comportamiento por defecto de `proxy_pass`).

## Balanceo de carga
Los upstreams se guardan en variables (`set $events_upstream ...`) y se usa
`resolver ${NGINX_LOCAL_RESOLVERS} valid=10s`. Con `proxy_pass` a una variable, nginx vuelve a
resolver el nombre cada 10 s. Con un `proxy_pass` estático resolvería **una sola vez al arrancar**,
fijaría una única IP y todas las peticiones irían siempre a la misma réplica: es lo que pasó en
la primera prueba local, con 8 de 8 llamadas a la misma réplica de ms-events.

- **Compose / Kubernetes:** el DNS del servicio devuelve las IPs de todas las réplicas y nginx
  alterna entre ellas (verificado: 5/5 entre 2 réplicas). Las réplicas nuevas entran en ≤ 10 s.
- **Container Apps:** el FQDN interno apunta a Envoy, que balancea (round robin) y solo envía
  tráfico a las réplicas que pasan la sonda *readiness*. Como el `resolver` de nginx no usa
  dominios de búsqueda, en Azure los upstreams son FQDN completos
  (`http://ms-events.internal.<defaultDomain>`), calculados en `containerapps.bicep`.

## Evolución
Azure API Management (tier Consumption) para cuotas por cliente, claves de suscripción,
validación de JWT y caché de respuestas.
