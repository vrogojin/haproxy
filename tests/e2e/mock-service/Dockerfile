FROM node:20-alpine

RUN apk add --no-cache openssl curl socat bash

COPY test-service-entrypoint.sh /entrypoint.sh
COPY ws-echo-server.mjs /ws-echo-server.mjs
COPY pp-echo-server.mjs /pp-echo-server.mjs
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
