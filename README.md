# Red Hat Connectivity Link on OpenShift (on-prem, GitOps)

This repo sets up the following, driven entirely from Git by OpenShift GitOps (Argo CD):

- **OpenShift Service Mesh 3** in sidecar mode, with **one Istio control plane** for both the mesh and the API gateway.
  Because the gateway is in the mesh, traffic from the gateway to your apps is mutual TLS.
- **Connectivity Link (Kuadrant)**: Authorino for API keys and OIDC/JWT, Limitador for rate limits, and TLSPolicy for cert-manager certificates.
- A shared **Gateway API gateway** with safe defaults: every route is denied unless it has its own AuthPolicy, plus a default rate limit and an HTTP→HTTPS redirect.
- **API keys from HashiCorp Vault**, synced by External Secrets Operator. Keys never live in Git.
- A path to **move apps off OpenShift Routes/Ingress** and onto HTTPRoutes.

Target: OpenShift 4.19+ on-prem, with MetalLB (or another LoadBalancer provider) and cert-manager already installed, a GitHub repo and a Vault server.

## How it fits together

```
bootstrap/bootstrap.sh  (run once by hand)
  └─ OpenShift GitOps operator + RBAC + health checks
     └─ rhcl-root Application  ──renders──  gitops/ (app-of-apps chart)
          wave 0  rhcl-operators     charts/rhcl-operators   + site/operators-values.yaml
          wave 0  external-secrets   upstream ESO chart 2.12.0
          wave 1  rhcl-platform      charts/rhcl-platform    + site/platform-values.yaml
          wave 1  vault-store        charts/vault-store      + site/vault-store-values.yaml
          wave 2  rhcl-apis          ApplicationSet: one Application per apis/<namespace>/<api>.yaml
```

- **Wave order.** Each wave starts only when the previous one is healthy. The custom health checks in `bootstrap/argocd-health-checks.yaml` teach Argo when Subscriptions, Istio, Kuadrant, Gateways, policies and ExternalSecrets are actually ready.
- **Day 2.** After bootstrap, every change is a commit:

| You want to… | Change in Git |
|---|---|
| Change the domain, issuer, LB IP, Istio version, mTLS mode | `site/platform-values.yaml` |
| Expose an API | add `apis/<namespace>/<api>.yaml` |
| Change an API's auth or rate limits | edit its file in `apis/` |
| Give a caller an API key | `scripts/vault-create-api-key.sh`, then add them under `consumers` |
| Revoke a caller | remove them from `consumers` (or delete the key in Vault) |
| Remove an API | delete its file |

## Repo layout

```
bootstrap/          one-time setup: GitOps operator, RBAC, health checks, root Application
gitops/             app-of-apps chart (Applications, sync waves, the apis/ ApplicationSet)
charts/
  rhcl-operators/   OLM subscriptions: servicemeshoperator3, rhcl-operator
  rhcl-platform/    IstioCNI, Istio, mTLS mode, Kuadrant, Gateway, TLSPolicy, default policies
  vault-store/      ClusterSecretStore for Vault (Kubernetes auth)
  api/              one API: HTTPRoute + AuthPolicy + RateLimitPolicy + API-key ExternalSecrets
site/               values for this cluster
apis/               one file per API
vault/setup.sh      one-time Vault configuration (run by a Vault admin)
scripts/
  vault-create-api-key.sh    generate an API key in Vault
  routes-to-api-values.py    turn existing Routes/Ingresses into apis/ files
  verify.sh                  check each layer and report what is not ready
```

## Setup

### 1. Fill in the site values and push to GitHub

| File | Set |
|---|---|
| `site/platform-values.yaml` | `gateway.hostname`, `tls.issuer.name`, and the LB IP in `gateway.serviceAnnotations` |
| `site/vault-store-values.yaml` | `server` (Vault URL) |
| `apis/echo-api/echo-api.yaml` | `hostnames`: under your gateway domain |

```bash
git init -b main && git add . && git commit -m "Connectivity Link platform"
```

```bash
gh repo create <org>/rhcl-gitops --private --source . --push
```

### 2. Configure Vault (once, by a Vault admin)

Run this with `vault` logged in as an admin and `oc` logged in to the cluster:

```bash
OCP_API=https://api.ocp.example.internal:6443 vault/setup.sh
```

It creates:

- a KV v2 mount (`secret`), if missing
- a Kubernetes auth mount for this cluster (`ocp-rhcl`)
- a read-only policy for `secret/rhcl/apikeys/*`
- the role `eso-rhcl`, bound to the External Secrets service account

If your API server uses a custom certificate from your internal CA, edit the script so it passes that CA instead of `kube-root-ca.crt`.

Create the demo API's first key:

```bash
scripts/vault-create-api-key.sh echo-api alice
```

### 3. Bootstrap the cluster (the only `oc apply`)

```bash
REPO_URL=https://github.com/<org>/rhcl-gitops.git GITHUB_TOKEN=<read-only token> bootstrap/bootstrap.sh
```

- `GITHUB_TOKEN` is needed only for a private repo: a fine-grained token with read access to the repo's contents.
- The script installs OpenShift GitOps, gives its controller cluster-admin, adds the health checks and creates the root Application.

Watch the waves sync in the Argo CD UI, or with:

```bash
oc get applications -n openshift-gitops -w
```

```bash
scripts/verify.sh
```

### 4. DNS (one record)

Kuadrant's DNSPolicy can't write to BIND, Infoblox or AD DNS. In your DNS, create:

```
*.api.example.internal.   A   <gateway address from verify.sh>
```

To automate DNS too, ExternalDNS can manage BIND/AD (RFC2136) or Infoblox records straight from Gateways and HTTPRoutes. It isn't a Red Hat-supported component.

### 5. Pin versions

After the first sync, commit two changes to `site/` so that operator upgrades don't silently upgrade the mesh:

- Set `mesh.version` in `site/platform-values.yaml` to the output of `oc get istio default -o jsonpath='{.spec.version}'`.
- Set `installPlanApproval: Manual` in `site/operators-values.yaml`.

### 6. Try the demo API

`KEY` is the output of `vault-create-api-key.sh` in step 2.

```bash
curl -i https://echo.api.example.internal/
```

returns `401`: no credentials.

```bash
curl -i -H "Authorization: APIKEY $KEY" https://echo.api.example.internal/
```

returns `200`.

To see a rate limit, add a caller on the `free` plan (60 requests a minute) and call it 70 times:

1. Create bob's key:

```bash
FREE=$(scripts/vault-create-api-key.sh echo-api bob)
```

2. Add `- user: bob` (plan `free`) under `consumers` in `apis/echo-api/echo-api.yaml`, commit, and wait for Argo to sync.
3. Run the loop. The last calls return `429`:

```bash
for i in $(seq 1 70); do curl -s -o /dev/null -w '%{http_code} ' -H "Authorization: APIKEY $FREE" https://echo.api.example.internal/; done
```

## Exposing an API

Add `apis/<namespace>/<api>.yaml`:

- The directory name is the namespace. Argo creates it if needed and labels it for sidecar injection and gateway access.
- The file name is the API name.

```yaml
# apis/shop/orders.yaml
hostnames: [orders.api.example.internal]
rules:
  - matches: [{path: {type: PathPrefix, value: /}}]
    backendRefs: [{name: orders, port: 8080}]
auth:
  mode: protected        # protected | public | none
  apiKey:
    enabled: true
    consumers:
      - {user: billing-service, plan: gold}
      - {user: partner-acme}             # gets auth.defaultPlan (free)
  oidc:
    enabled: true
    issuerUrl: https://sso.example.internal/realms/api
    audience: orders-api
rateLimit:
  perUser:
    plans:
      free: {limit: 60, window: 1m}
      gold: {limit: 1000, window: 1m}
  total: {limit: 5000, window: 1m}
```

How the pieces fit:

- **Auth.** Callers send either `Authorization: APIKEY <key>` or `Authorization: Bearer <jwt>`. Either one is enough.
- **Where keys live.** Each consumer's key is in Vault at `secret/rhcl/apikeys/<api>/<user>` (field `api_key`). An ExternalSecret syncs it into `kuadrant-system`, where Authorino reads it.
- **Rotating a key.** Re-run `vault-create-api-key.sh`. The new key reaches the gateway within `refreshInterval` (15 minutes by default).
- **Per-user limits.** The RateLimitPolicy counts per caller, with a limit for each plan:
  - for an API key, the caller is its `user` and the plan is its `plan`;
  - for a JWT, the caller is `sub` and the plan comes from the `plan` claim (`auth.oidc.planClaim`).
- **Unlisted plans.** A caller whose plan is not in `rateLimit.perUser.plans` gets only the route-wide `total` limit.
- **Existing pods.** In a namespace that already existed, existing pods get the sidecar only after a restart: `oc rollout restart deployment -n <namespace>`.

### Trusting an internal CA for OIDC

Authorino fetches your IdP's discovery document and keys over HTTPS. If the IdP's certificate comes from an internal CA, Authorino must trust it.

To do that, add the CA to the cluster trust bundle (`oc get proxy cluster -o jsonpath='{.spec.trustedCA.name}'`) and mount the bundle into Authorino:

1. Create a ConfigMap that OpenShift fills with the bundle:

```bash
oc create configmap internal-ca-bundle -n kuadrant-system
```

```bash
oc label configmap internal-ca-bundle -n kuadrant-system config.openshift.io/inject-trusted-cabundle=true
```

2. Mount it into Authorino:

```bash
oc patch authorino authorino -n kuadrant-system --type merge -p '{"spec":{"volumes":{"items":[{"name":"internal-ca","mountPath":"/etc/ssl/certs","configMaps":["internal-ca-bundle"],"items":[{"key":"ca-bundle.crt","path":"ca-bundle.crt"}]}]}}}'
```

This is still a manual step, because the Kuadrant operator owns the Authorino CR. If you only use API keys, you don't need it.

## Migrating off Routes/Ingress

The **default IngressController (router) stays**. It serves the web console, OAuth, monitoring and other `openshift-*` routes, and must not be removed. What you migrate is your applications' Routes and Ingresses. Once that is done, the router serves only the platform.

1. Generate API files from what you have:

```bash
oc get routes,ingresses,services -A -o json > cluster.json
```

```bash
scripts/routes-to-api-values.py cluster.json --gateway-hostname '*.api.example.internal'
```

   - The script writes `apis/<namespace>/<name>.yaml` and `migration-report.md`. It never overwrites an existing file.
   - Add `--rehost apps.ocp.example.internal=api.example.internal` to move apps to the new domain while you're at it.
   - Without it, hostnames stay the same, and the report lists the extra gateway listeners they need.
2. Follow `migration-report.md`:
   1. **Add listeners.** If the report lists any, add them to `site/platform-values.yaml`.
   2. **Commit the API files.** Each starts as `auth.mode: public` so behaviour doesn't change. Read the `WARNING` lines at the top of each file.
   3. **Restart the workloads** so they get sidecars. With `mtlsMode: PERMISSIVE`, the old Routes keep working.
   4. **Test** through the gateway with `curl --resolve` before touching DNS.
   5. **Cut over DNS.**
      - New domain: nothing to do, the wildcard already points at the gateway.
      - Same hostname: add a specific A record for that hostname pointing at the gateway. It overrides the `*.apps` wildcard.
   6. **Delete the old Route or Ingress** (in Git, if that's where it lives).
3. Tighten each API: switch `auth.mode` to `protected` and add `consumers`.
4. When no app traffic uses the router any more, set `mesh.mtlsMode: STRICT` in `site/platform-values.yaml`.

Not converted automatically:

- **Passthrough Routes.** These need a TLSRoute and a passthrough listener.
- **Reencrypt Routes.** The app can serve plain HTTP inside the mesh, because the sidecars handle mTLS.
- **HAProxy annotations** other than `timeout`. For example, `ip_whitelist` becomes an AuthPolicy rule on `source.address`.

## Notes

- **Don't create** a GatewayClass with `controllerName: openshift.io/gateway-controller/v1`. That makes OpenShift install a second, gateway-only Istio that is not part of this mesh.
- **Argo CD permissions.** The `openshift-gitops` instance gets cluster-admin because it installs operators and cluster-scoped resources. Give application teams their own namespace-scoped Argo CD instance, or limit them with AppProjects.
- **NetworkPolicies.** In namespaces that have them, allow ingress from `api-gateway`. The Istio sidecars also need to reach `istio-system`.
- **Pruning safety.** Subscriptions and namespaces carry `argocd.argoproj.io/sync-options: Delete=false`, so removing something from Git never uninstalls the operators or deletes a namespace.
- **Without Argo CD.** The charts in `charts/` still work with plain `helm upgrade --install` in wave order. Pass `site/*.yaml` and `apis/*/*.yaml` as values files, and label app namespaces with `istio-injection=enabled` and `api-gateway-access=true`.
