#!/bin/bash
set -euo pipefail

# Install kubectl
KUBE_VERSION=$(curl -sL https://dl.k8s.io/release/stable.txt | tr -d '\r\n[:space:]')
echo "Installing kubectl version: $KUBE_VERSION"
curl -sLO "https://dl.k8s.io/release/${KUBE_VERSION}/bin/linux/amd64/kubectl"
chmod +x kubectl && mv kubectl /usr/local/bin/

# Install Vault CLI
VAULT_VER=$(curl -s https://checkpoint-api.hashicorp.com/v1/check/vault | jq -r '.current_version' | tr -d '\r\n[:space:]\000-\037\177')
echo "Installing Vault CLI version: $VAULT_VER"
DOWNLOAD_URL="https://releases.hashicorp.com/vault/${VAULT_VER}/vault_${VAULT_VER}_linux_amd64.zip"
echo "Download URL: $DOWNLOAD_URL"
curl -sSfL -o vault.zip "$DOWNLOAD_URL"
unzip -j vault.zip vault
chmod +x vault && mv vault /usr/local/bin/

: "${VAULT_ADDR:?VAULT_ADDR must be set as an environment variable}"

# Bootstrap Vault Transit
until vault status -format=json | jq -e '.initialized == false and .sealed == true' >/dev/null; do
    vault status -format=json
    echo "Waiting for Vault to be reachable and uninitialized..." && sleep 2
done
vault operator init -format=json -key-shares=5 -key-threshold=3 >/tmp/init.json
for i in 0 1 2; do
    vault operator unseal "$(jq -r ".unseal_keys_b64[$i]" /tmp/init.json)"
done
VAULT_TOKEN=$(jq -r ".root_token" /tmp/init.json)
export VAULT_TOKEN
vault secrets enable transit
vault write -f transit/keys/autounseal
vault policy write autounseal - <<EOF
path "transit/encrypt/autounseal" { capabilities = ["update"] }
path "transit/decrypt/autounseal" { capabilities = ["update"] }
EOF
TOKEN=$(vault token create -policy=autounseal -period=8760h -format=json | jq -r '.auth.client_token')
kubectl delete secret vault-b-unseal-token -n vault --ignore-not-found
kubectl create secret generic vault-b-unseal-token -n vault --from-literal=token="$TOKEN"
echo "✅ Done."
