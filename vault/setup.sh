#!/usr/bin/env bash
# One-time Vault configuration, run by a Vault admin (needs `vault` CLI, VAULT_ADDR and an admin token).
#   OCP_API=https://api.ocp.example.internal:6443 vault/setup.sh
# Creates a Kubernetes auth mount for this cluster, a read-only policy for API keys,
# and the role the External Secrets controller logs in with. Names must match site/vault-store-values.yaml.
set -euo pipefail

: "${OCP_API:?set OCP_API to the cluster API URL}"
MOUNT=${MOUNT:-ocp-rhcl}
ROLE=${ROLE:-eso-rhcl}
KV=${KV:-secret}
PREFIX=${PREFIX:-rhcl/apikeys}

# CA that signed the cluster API certificate (run with an `oc` session on the cluster).
ca=$(mktemp)
trap 'rm -f "$ca"' EXIT
oc get configmap kube-root-ca.crt -n openshift-config -o jsonpath='{.data.ca\.crt}' > "$ca"

vault secrets list -format=json | grep -q "\"$KV/\"" || vault secrets enable -path="$KV" kv-v2
vault auth list -format=json | grep -q "\"$MOUNT/\"" || vault auth enable -path="$MOUNT" kubernetes

# No token_reviewer_jwt: Vault uses the client's own token for TokenReview
# (the vault-store chart grants it system:auth-delegator).
vault write "auth/$MOUNT/config" kubernetes_host="$OCP_API" kubernetes_ca_cert=@"$ca"

vault policy write "$ROLE" - <<POLICY
path "$KV/data/$PREFIX/*"     { capabilities = ["read"] }
path "$KV/metadata/$PREFIX/*" { capabilities = ["read", "list"] }
POLICY

vault write "auth/$MOUNT/role/$ROLE" \
  bound_service_account_names=external-secrets \
  bound_service_account_namespaces=external-secrets \
  policies="$ROLE" \
  ttl=1h

echo "Vault is ready. Write keys with scripts/vault-create-api-key.sh."
