#!/usr/bin/env bash
# Generate an API key in Vault and print it once. Then add the consumer to the API's file in apis/.
#   vault-create-api-key.sh <api-name> <user-id>
# Rotating: run it again for the same user; the gateway picks it up within refreshInterval.
set -euo pipefail

api=${1:?usage: $0 <api-name> <user-id>}
user=${2:?usage: $0 <api-name> <user-id>}
kv=${KV:-secret}
prefix=${PREFIX:-rhcl/apikeys}
key=$(openssl rand -hex 24)

vault kv put -mount="$kv" "$prefix/$api/$user" api_key="$key" >/dev/null
echo "$key"
cat >&2 <<MSG
Stored in Vault at $kv/$prefix/$api/$user.
If $user is not already listed, add it to the API's file in apis/ and commit:
    consumers:
      - user: $user
        plan: free
MSG
