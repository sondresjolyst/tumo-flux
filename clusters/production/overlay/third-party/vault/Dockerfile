FROM debian:stable-slim

RUN apt-get update && apt-get install -y curl jq ca-certificates unzip bsdmainutils

COPY vault-bootstrap-script.sh /vault-bootstrap.sh
RUN chmod +x /vault-bootstrap.sh

ENTRYPOINT ["/vault-bootstrap.sh"]