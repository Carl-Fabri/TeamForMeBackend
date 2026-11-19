# Imagen de Prometheus para Azure Container Apps (la configuración va dentro de la imagen).
# El dominio interno del entorno se conoce al desplegar: entrypoint.sh lo inserta al arrancar.
FROM prom/prometheus:v3.5.0
COPY prometheus.aca.yml /etc/prometheus/prometheus.aca.yml
COPY rules.yml /etc/prometheus/rules.yml
COPY --chmod=755 entrypoint.sh /etc/prometheus/entrypoint.sh
ENTRYPOINT ["/etc/prometheus/entrypoint.sh"]
CMD []
