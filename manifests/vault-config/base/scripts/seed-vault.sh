#!/bin/sh
# Seeds the dev Vault so the two demo apps can authenticate and read secrets.
# Idempotent: safe to re-run on every Argo CD sync.
set -eu

echo "==> waiting for Vault at ${VAULT_ADDR}"
until vault status >/dev/null 2>&1; do
  echo "    ...not ready yet"
  sleep 3
done
echo "    Vault is up"

# --- Kubernetes auth method -------------------------------------------------
# This is what lets a Pod prove its identity to Vault using nothing but its
# ServiceAccount token. Vault calls TokenReview to validate it, which is why
# the vault ServiceAccount is bound to system:auth-delegator.
echo "==> enabling the kubernetes auth method"
if vault auth list -format=json | grep -q '"kubernetes/"'; then
  echo "    already enabled"
else
  vault auth enable kubernetes
fi

echo "==> configuring the kubernetes auth method"
vault write auth/kubernetes/config \
  kubernetes_host="https://${KUBERNETES_SERVICE_HOST}:${KUBERNETES_SERVICE_PORT_HTTPS:-443}" \
  disable_iss_validation=true

# --- KV v2 secrets ----------------------------------------------------------
# Dev-mode Vault already mounts a KV v2 engine at secret/.
# Values arrive as env vars from a kustomize-generated Secret, so the key=value
# properties file in config/ is the single source of truth for them.
echo "==> writing secret/payments-api/database"
vault kv put secret/payments-api/database \
  username="${PAYMENTS_DB_USERNAME}" \
  password="${PAYMENTS_DB_PASSWORD}" \
  url="${PAYMENTS_DB_URL}"

echo "==> writing secret/inventory-web/api"
vault kv put secret/inventory-web/api \
  api_key="${INVENTORY_API_KEY}" \
  api_endpoint="${INVENTORY_API_ENDPOINT}" \
  webhook_signing_key="${INVENTORY_WEBHOOK_SIGNING_KEY}"

# --- Policies: least privilege, one per app ---------------------------------
echo "==> writing policies"
vault policy write payments-api - <<'EOF'
path "secret/data/payments-api/*" {
  capabilities = ["read"]
}
path "secret/metadata/payments-api/*" {
  capabilities = ["read", "list"]
}
EOF

vault policy write inventory-web - <<'EOF'
path "secret/data/inventory-web/*" {
  capabilities = ["read"]
}
path "secret/metadata/inventory-web/*" {
  capabilities = ["read", "list"]
}
EOF

# --- Roles: bind a ServiceAccount identity to a policy -----------------------
# bound_service_account_names / _namespaces are the whole security story:
# only the payments-api SA in the payments-demo namespace can get this policy.
echo "==> writing kubernetes auth roles"
vault write auth/kubernetes/role/payments-api \
  bound_service_account_names=payments-api \
  bound_service_account_namespaces=payments-demo \
  policies=payments-api \
  ttl=24h

vault write auth/kubernetes/role/inventory-web \
  bound_service_account_names=inventory-web \
  bound_service_account_namespaces=inventory-demo \
  policies=inventory-web \
  ttl=24h

echo "==> Vault seeded successfully"
