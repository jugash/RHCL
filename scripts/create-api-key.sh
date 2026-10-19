#!/usr/bin/env bash
# Create an API key for an API deployed with charts/api, and print it once.
#   create-api-key.sh <api-name> <user-id> [plan]
# The plan selects the per-user rate limit (rateLimit.perUser.plans in the api chart).
# Revoke a key with: oc delete secret apikey-<api-name>-<user-id> -n kuadrant-system
set -euo pipefail

api=${1:?usage: $0 <api-name> <user-id> [plan]}
user=${2:?usage: $0 <api-name> <user-id> [plan]}
plan=${3:-free}
key=$(openssl rand -hex 24)

oc apply -f - >/dev/null <<YAML
apiVersion: v1
kind: Secret
metadata:
  name: apikey-${api}-${user}
  namespace: kuadrant-system
  labels:
    authorino.kuadrant.io/managed-by: authorino
    api: ${api}
  annotations:
    secret.kuadrant.io/user-id: ${user}
    secret.kuadrant.io/plan-id: ${plan}
type: Opaque
stringData:
  api_key: ${key}
YAML

echo "$key"
