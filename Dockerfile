# Dockerfile
FROM alpine:3.24

RUN apk add --no-cache bash curl jq ca-certificates

COPY . /repo/

RUN cp /repo/certs/*.crt /usr/local/share/ca-certificates/ \
    && update-ca-certificates

RUN find /repo/src -type f -name '*.sh' -exec chmod +x {} +

RUN bash /repo/test/run-tests.sh

RUN cp -r /repo/src/. /app/

ENV DB_DIR=/db

ENTRYPOINT ["/app/entrypoint.sh"]
