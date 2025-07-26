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

# Set secret names per role
if [[ "$ROLE" == "transit" ]]; then
    INIT_SECRET="vault-b-init"
    UNSEAL_SECRET="vault-b-unseal-token"
    NAMESPACE="vault"
elif [[ "$ROLE" == "main" ]]; then
    INIT_SECRET="vault-main-init"
    UNSEAL_SECRET="vault-b-unseal-token"
    NAMESPACE="vault"
else
    echo "ERROR: Unknown ROLE: $ROLE. Must be 'transit' or 'main'."
    exit 1
fi

# Restore /tmp/init.json from secret if missing
if [ ! -f /tmp/init.json ]; then
    echo "[${ROLE}] Attempting to restore /tmp/init.json from secret $INIT_SECRET in namespace $NAMESPACE..."
    kubectl get secret "$INIT_SECRET" -n "$NAMESPACE" -o jsonpath='{.data.init\.json}' 2>/dev/null | base64 -d > /tmp/init.json || true
    if [ -s /tmp/init.json ]; then
        echo "[${ROLE}] Restored /tmp/init.json from secret."
    else
        rm -f /tmp/init.json
        echo "[${ROLE}] No existing init.json found in secret."
    fi
fi

if [[ "$ROLE" == "transit" ]]; then
    echo "[transit] Bootstrapping Transit Vault..."
    # Wait for Vault API to be reachable
    for i in {1..60}; do
        status=$(curl -s -o /dev/null -w "%{http_code}" "$VAULT_ADDR/v1/sys/health" || true)
        if [ "$status" = "501" ] || [ "$status" = "503" ] || [ "$status" = "429" ] || [ "$status" = "200" ]; then
            echo "[transit] Vault API is reachable (status $status)."
            break
        fi
        echo "[transit] Waiting for Vault API... ($i/60, status $status)"
        sleep 5
    done
    # Robust check for initialization status
    init_status=$(curl -s $VAULT_ADDR/v1/sys/health | jq -r .initialized)
    if [ "$init_status" = "false" ]; then
        echo "[transit] Vault is uninitialized, proceeding with initialization."
        vault operator init -format=json -key-shares=5 -key-threshold=3 >/tmp/init.json
        for i in 0 1 2; do
            vault operator unseal "$(jq -r ".unseal_keys_b64[$i]" /tmp/init.json)"
        done
        VAULT_TOKEN=$(jq -r ".root_token" /tmp/init.json)
        export VAULT_TOKEN
        # Save /tmp/init.json to secret
        kubectl delete secret "$INIT_SECRET" -n "$NAMESPACE" --ignore-not-found
        kubectl create secret generic "$INIT_SECRET" -n "$NAMESPACE" --from-file=init.json=/tmp/init.json
        echo "[transit] Saved /tmp/init.json to secret $INIT_SECRET."
    else
        echo "[transit] Vault already initialized. Attempting to unseal if needed."
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
    kubectl delete secret "$UNSEAL_SECRET" -n "$NAMESPACE" --ignore-not-found
    kubectl create secret generic "$UNSEAL_SECRET" -n "$NAMESPACE" --from-literal=token="$TOKEN"
    echo "[transit] ✅ Transit Vault bootstrap complete."

elif [[ "$ROLE" == "main" ]]; then
    echo "[main] Bootstrapping Main Vault..."
    # Wait for the unseal token secret from transit Vault
    for i in {1..60}; do
        TOKEN=$(kubectl get secret "$UNSEAL_SECRET" -n "$NAMESPACE" -o jsonpath='{.data.token}' | base64 -d 2>/dev/null || true)
        if [[ -n "$TOKEN" ]]; then
            echo "[main] Found unseal token from transit Vault."
            break
        fi
        echo "[main] Waiting for $UNSEAL_SECRET secret... ($i/60)"
        sleep 5
    done
    if [[ -z "$TOKEN" ]]; then
        echo "[main] ERROR: Could not retrieve unseal token from transit Vault."
        exit 1
    fi
    export VAULT_TOKEN="$TOKEN"
    # Wait for Vault API to be reachable
    for i in {1..60}; do
        status=$(curl -s -o /dev/null -w "%{http_code}" "$VAULT_ADDR/v1/sys/health" || true)
        if [ "$status" = "501" ] || [ "$status" = "503" ] || [ "$status" = "429" ] || [ "$status" = "200" ]; then
            echo "[main] Vault API is reachable (status $status)."
            break
        fi
        echo "[main] Waiting for Vault API... ($i/60, status $status)"
        sleep 5
    done
    init_status=$(curl -s $VAULT_ADDR/v1/sys/health | jq -r .initialized)
    if [ "$init_status" = "false" ]; then
        echo "[main] Vault is uninitialized, proceeding with initialization."
        vault operator init -format=json -key-shares=5 -key-threshold=3 >/tmp/init.json
        for i in 0 1 2; do
            vault operator unseal "$(jq -r ".unseal_keys_b64[$i]" /tmp/init.json)"
        done
        # Save /tmp/init.json to secret
        kubectl delete secret "$INIT_SECRET" -n "$NAMESPACE" --ignore-not-found
        kubectl create secret generic "$INIT_SECRET" -n "$NAMESPACE" --from-file=init.json=/tmp/init.json
        echo "[main] Saved /tmp/init.json to secret $INIT_SECRET."
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
fi
