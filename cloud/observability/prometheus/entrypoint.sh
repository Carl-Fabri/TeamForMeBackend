#!/bin/sh
# Genera la configuración de Prometheus para Container Apps sustituyendo ${APPS_DOMAIN}
# (lo define containerapps.bicep) y arranca Prometheus con los argumentos por defecto.
set -e
if [ -z "$APPS_DOMAIN" ]; then
  echo "Falta la variable APPS_DOMAIN (dominio por defecto del entorno de Container Apps)" >&2
  exit 1
fi
sed "s|\${APPS_DOMAIN}|$APPS_DOMAIN|g" /etc/prometheus/prometheus.aca.yml > /prometheus/prometheus.yml
exec /bin/prometheus --config.file=/prometheus/prometheus.yml --storage.tsdb.path=/prometheus "$@"
