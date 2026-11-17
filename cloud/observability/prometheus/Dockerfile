# Imagen de Prometheus para Azure Container Apps (la configuración va dentro de la imagen).
FROM prom/prometheus:v3.5.0
COPY prometheus.aca.yml /etc/prometheus/prometheus.yml
COPY rules.yml /etc/prometheus/rules.yml
