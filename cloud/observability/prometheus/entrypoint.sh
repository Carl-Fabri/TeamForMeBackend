#!/bin/sh
# Genera la configuración de Prometheus para Container Apps sustituyendo ${INTERNAL_SUFFIX}
# (lo define containerapps.bicep) y arranca Prometheus con los argumentos por defecto.
set -e
if [ -z "$INTERNAL_SUFFIX" ]; then
  echo "Falta la variable INTERNAL_SUFFIX (internal.<dominio-del-entorno>)" >&2
  exit 1
fi
sed "s|\${INTERNAL_SUFFIX}|$INTERNAL_SUFFIX|g" /etc/prometheus/prometheus.aca.yml > /prometheus/prometheus.yml
exec /bin/prometheus --config.file=/prometheus/prometheus.yml --storage.tsdb.path=/prometheus "$@"
