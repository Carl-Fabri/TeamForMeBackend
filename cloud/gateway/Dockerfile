# Imagen del API Gateway. La plantilla se procesa con envsubst al iniciar el contenedor.
FROM nginx:1.27-alpine
COPY default.conf.template /etc/nginx/templates/default.conf.template
ENV EVENTS_UPSTREAM=http://ms-events:8080 \
    TEAMS_UPSTREAM=http://ms-teams:8080 \
    APPLICATIONS_UPSTREAM=http://ms-applications:8080 \
    USERS_UPSTREAM=http://ms-users:8080 \
    NOTIFICATIONS_UPSTREAM=http://ms-notifications:8080 \
    FRONTEND_UPSTREAM=http://frontend:4000
# Habilita el cálculo de NGINX_LOCAL_RESOLVERS (usado por "resolver" en la plantilla).
ENV NGINX_ENTRYPOINT_LOCAL_RESOLVERS=1
EXPOSE 8080
