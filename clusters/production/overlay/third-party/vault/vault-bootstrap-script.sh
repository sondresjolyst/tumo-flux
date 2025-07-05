#!/bin/bash
set -euo pipefail

ROLE=${ROLE:-transit} # Default to 'transit' if not set

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

if [[ "$ROLE" == "transit" ]]; then
  echo "[transit] Bootstrapping Transit Vault..."
  if vault status | grep -q 'Initialized.*false'; then
    echo "[transit] Vault is uninitialized, proceeding with initialization."
    vault operator init -format=json -key-shares=5 -key-threshold=3 >/tmp/init.json
    for i in 0 1 2; do
      vault operator unseal "$(jq -r ".unseal_keys_b64[$i]" /tmp/init.json)"
    done
    VAULT_TOKEN=$(jq -r ".root_token" /tmp/init.json)
    export VAULT_TOKEN
  else
    echo "[transit] Vault already initialized. Attempting to unseal if needed."
    # Try to unseal with known keys if possible (idempotency)
    if [ -f /tmp/init.json ]; then
      for i in 0 1 2; do
        vault operator unseal "$(jq -r ".unseal_keys_b64[$i]" /tmp/init.json)" || true
      done
      VAULT_TOKEN=$(jq -r ".root_token" /tmp/init.json)
      export VAULT_TOKEN
    else
      echo "[transit] No init.json found, skipping unseal."
    fi
  fi
  # Enable transit and create key/policy/token if not already present
  if ! vault secrets list | grep -q '^transit/'; then
    vault secrets enable transit
  fi
  if ! vault read transit/keys/autounseal >/dev/null 2>&1; then
    vault write -f transit/keys/autounseal
  fi
  vault policy write autounseal - <<EOF
path "transit/encrypt/autounseal" { capabilities = ["update"] }
path "transit/decrypt/autounseal" { capabilities = ["update"] }
EOF
  TOKEN=$(vault token create -policy=autounseal -period=8760h -format=json | jq -r '.auth.client_token')
  kubectl delete secret vault-b-unseal-token -n vault --ignore-not-found
  kubectl create secret generic vault-b-unseal-token -n vault --from-literal=token="$TOKEN"
  echo "[transit] ✅ Transit Vault bootstrap complete."

elif [[ "$ROLE" == "main" ]]; then
  echo "[main] Bootstrapping Main Vault..."
  # Wait for the unseal token secret from transit Vault
  for i in {1..60}; do
    TOKEN=$(kubectl get secret vault-b-unseal-token -n vault -o jsonpath='{.data.token}' | base64 -d 2>/dev/null || true)
    if [[ -n "$TOKEN" ]]; then
      echo "[main] Found unseal token from transit Vault."
      break
    fi
    echo "[main] Waiting for vault-b-unseal-token secret... ($i/60)"
    sleep 5
  done
  if [[ -z "$TOKEN" ]]; then
    echo "[main] ERROR: Could not retrieve unseal token from transit Vault."
    exit 1
  fi
  export VAULT_TOKEN="$TOKEN"
  if vault status | grep -q 'Initialized.*false'; then
    echo "[main] Vault is uninitialized, proceeding with initialization."
    vault operator init -format=json -key-shares=5 -key-threshold=3 >/tmp/init.json
    for i in 0 1 2; do
      vault operator unseal "$(jq -r ".unseal_keys_b64[$i]" /tmp/init.json)"
    done
  else
    echo "[main] Vault already initialized. Attempting to unseal if needed."
    if [ -f /tmp/init.json ]; then
      for i in 0 1 2; do
        vault operator unseal "$(jq -r ".unseal_keys_b64[$i]" /tmp/init.json)" || true
      done
    else
      echo "[main] No init.json found, skipping unseal."
    fi
  fi
  echo "[main] ✅ Main Vault bootstrap complete."
else
  echo "ERROR: Unknown ROLE: $ROLE. Must be 'transit' or 'main'."
  exit 1
fi
