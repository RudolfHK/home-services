FROM nginx:alpine

COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY src /usr/share/nginx/html
# Templates config.js from config.js.template at container start (envsubst
# ships in this base image already, used internally for its own config
# templating) — see docker-entrypoint.d/30-inject-api-token.sh.
COPY docker-entrypoint.d/30-inject-api-token.sh /docker-entrypoint.d/30-inject-api-token.sh
RUN chmod +x /docker-entrypoint.d/30-inject-api-token.sh
