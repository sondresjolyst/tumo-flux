FROM debian:stable-slim

ARG VAULT_ADDR=http://vault-0.vault-transit.svc:8200
ENV VAULT_ADDR=${VAULT_ADDR}

RUN apt-get update && apt-get install -y curl jq ca-certificates unzip bsdmainutils

COPY vault-bootstrap-script.sh /vault-bootstrap.sh
RUN chmod +x /vault-bootstrap.sh

ENTRYPOINT ["/vault-bootstrap.sh"]