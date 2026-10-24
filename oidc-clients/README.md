Keycloak clients for callers of the APIs in `apis/`, as `KeycloakClient` resources for
keycloak-client-operator. They are examples: nothing here is deployed by Argo CD. Copy one
into the caller's own repo or namespace and change the names.

| File | Caller | Grant | Client |
|---|---|---|---|
| `shop-web.yaml` | Single-page app, users sign in | Authorization code + PKCE | Public |
| `portal.yaml` | Server-rendered web app, users sign in | Authorization code | Confidential |
| `billing-service.yaml` | Backend, no user | Client credentials | Confidential |

All three are in the realm `api`, which `issuerUrl` in `apis/` points at
(`https://sso.example.internal/realms/api`).

**Fields that depend on the kind of client**

| Field | What it is | Set it for |
|---|---|---|
| `redirectUris` | Where Keycloak may send the user back after login. Exact URLs, or a trailing `/*` | Clients where users sign in |
| `postLogoutRedirectUris` | Where Keycloak may send the user after logout | Clients where users sign in |
| `webOrigins` | Origins allowed to call Keycloak's own endpoints from JavaScript. `"+"` means the origins of `redirectUris` | Single-page apps only |
| `serviceAccountsEnabled` | Turns on the client credentials grant, and gives the client its own user for the token's `sub` | Backends with no user |

- **Narrow redirect URIs.** `https://app.example.internal/*` is fine. `*` or `https://*` would
  let anyone receive your users' authorization codes.
- **HTTPS only.** The Kyverno policy `enforce-https-redirect-uris` rejects `http://` redirect
  URIs except on `localhost` and `127.0.0.1`.
- **No API hostnames.** `orders.api.example.internal` never belongs in `redirectUris` or
  `webOrigins`: the API only receives tokens, it doesn't take part in the login.
- **`webOrigins` is CORS on Keycloak, not on your API.** If a browser calls an API hostname
  directly, the gateway has to answer the CORS preflight. Serving the API under the app's own
  hostname avoids that.

**Claims the gateway reads**

Each client has two protocol mappers, so its tokens work with the `charts/api` AuthPolicy:

- **`aud`.** If the API sets `auth.oidc.audience` (here `orders-api`), tokens without it are
  rejected. The `oidc-audience-mapper` adds it.
- **`plan`.** The per-caller rate limit reads the plan from `auth.oidc.planClaim` (`plan`).
  Clients where users sign in take it from the user's `plan` attribute. The backend has no
  user, so it gets a fixed one. A token without the claim gets `auth.defaultPlan`.

**Credentials**

For a confidential client, the operator writes the Secret named in `credentialsSecretRef`
(default `<clientId>-credentials`) into the client's namespace, with the fields `client-id`
and `client-secret`. A public client has none.

To get a token as `billing-service` and call the API:

```bash
secret=$(oc get secret billing-service-oidc -n billing -o jsonpath='{.data.client-secret}' | base64 -d)
```

```bash
token=$(curl -s -u "billing-service:$secret" -d grant_type=client_credentials https://sso.example.internal/realms/api/protocol/openid-connect/token | jq -r .access_token)
```

```bash
curl -H "Authorization: Bearer $token" https://orders.api.example.internal/
```
