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
          wave 0  rhcl-operators     charts/rhcl-operators   + site/operators-values.yaml  (OSSM 3 → servicemesh-operator, RHCL → kuadrant-system)
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
gitops/             app-of-apps chart (Applications, sync waves, the apis/ and examples/ ApplicationSets)
charts/
  rhcl-operators/   OLM subscriptions: servicemeshoperator3, rhcl-operator
  rhcl-platform/    IstioCNI, Istio, mTLS mode, Kuadrant, Gateway, TLSPolicy, default policies
  vault-store/      ClusterSecretStore for Vault (Kubernetes auth)
  api/              one API: HTTPRoute + AuthPolicy + RateLimitPolicy + API-key ExternalSecrets
site/               values for this cluster
apis/               one file per API
examples/           test APIs as plain manifests, each in its own rhcl-ex-* namespace
oidc-clients/       example Keycloak clients for API callers (not deployed)
manifests/          the platform as plain manifests + oc-only apply.sh, for clusters without Helm/Argo CD
vault/setup.sh      one-time Vault configuration (run by a Vault admin)
scripts/
  vault-create-api-key.sh    generate an API key in Vault
  routes-to-api-values.py    turn existing Routes/Ingresses into apis/ files
  verify.sh                  check each layer and report what is not ready
  test-examples.sh           end-to-end tests against examples/, plus no-impact checks
```

## Setup

### 1. Fill in the site values and push to GitHub

| File | Set |
|---|---|
| `site/platform-values.yaml` | `gateway.hostname`, `tls.issuer.name`, and the LB IP in `gateway.serviceAnnotations` |
| `site/vault-store-values.yaml` | `server` (Vault URL) |
| `examples/*/20-httproute.yaml` | hostnames, if your gateway domain isn't `api.example.internal` |

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

Create the keys used by the API-key example:

```bash
scripts/vault-create-api-key.sh echo alice
```

```bash
scripts/vault-create-api-key.sh echo bob
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

### 6. Test with the examples

`examples/` holds three small test APIs as plain Kubernetes manifests (Namespace, Deployment, Service, HTTPRoute, AuthPolicy, RateLimitPolicy, ExternalSecret). Read them to see how each feature is wired; [examples/README.md](examples/README.md) lists the files. Nothing in them touches your current setup:

- **Own namespaces.** Each example runs in a new `rhcl-ex-*` namespace. Only those namespaces get the sidecar and gateway labels.
- **Own address.** The gateway has its own LoadBalancer IP and its own domain. The OpenShift router, its `*.apps` wildcard and your Routes/Ingresses stay as they are.
- **No DNS needed.** The test script sends requests straight to the gateway IP with `curl --resolve`, so you don't need the DNS record from step 4 yet.

| Example | Expect |
|---|---|
| `hello` (`rhcl-ex-public`) | `200` without credentials; `429` after 5 requests in 10s |
| `echo` (`rhcl-ex-apikey`) | `401` without a key; `200` for alice and bob; bob (free, 3/10s) hits `429` while alice (gold) doesn't |
| `locked` (`rhcl-ex-locked`) | `403`: no AuthPolicy, so the gateway's deny-all default applies |

Run the tests. Add a few of your current Route URLs so the script also confirms they still respond:

```bash
EXISTING_URLS="https://myapp.apps.ocp.example.internal/" scripts/test-examples.sh
```

What the script checks:

- **Gateway:** certificate, HTTP→HTTPS redirect, every expectation in the table, per-user isolation, and that gateway→app traffic is mutual TLS.
- **Network policies:** each example namespace denies everything except the gateway's pods and the sidecar's istiod/DNS traffic, so the tests above pass with everything else locked down.
- **No impact:** no namespace outside the repo got the mesh or gateway labels, no HTTPRoute exists outside the repo's namespaces, and the default IngressController is still available.

Pass `CACERT=<your internal CA file>` to verify the certificate instead of skipping verification.

To remove the examples, set `examples.enabled: false` in `gitops/values.yaml` and push. Argo deletes the APIs, but not the `rhcl-ex-*` namespaces. To remove those too:

```bash
oc delete ns rhcl-ex-public rhcl-ex-apikey rhcl-ex-locked
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
- **OIDC callers.** [oidc-clients/](oidc-clients/README.md) has example Keycloak clients: a single-page app, a server-side web app and a backend. Each one shows its redirect URIs and web origins, and the `aud` and `plan` claims the AuthPolicy reads.

### Trusting an internal CA for OIDC

Authorino fetches your IdP's discovery document and keys over HTTPS. If an internal CA signed the IdP's certificate, Authorino must trust that CA. If you only use API keys, you don't need this.

1. Add the CA to the cluster trust bundle (`oc get proxy cluster -o jsonpath='{.spec.trustedCA.name}'`).
2. In `site/platform-values.yaml`, set:

```yaml
authorino:
  trustedCA:
    enabled: true
```

The platform chart then declares the `Authorino` CR itself, with the cluster trust bundle mounted at `/etc/ssl/certs`. Nothing is patched by hand. The Kuadrant operator creates that CR only when it is missing. Once it exists, the operator server-side-applies just the TLS and tracing fields, so Argo keeps the CA volume, and upgrades keep it too.

To use your own CA bundle instead of the cluster one, set `authorino.trustedCA.configMap` to a ConfigMap in `kuadrant-system`. It replaces the image's CAs, so it must hold the public CAs as well as yours.

Without Argo CD, apply `manifests/optional/authorino-trust-internal-ca.yaml` instead.

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

## Clusters that restrict traffic between namespaces

If your NetworkPolicies isolate namespaces from each other, set `networkPolicies.enabled: true` in
`site/platform-values.yaml` and `site/vault-store-values.yaml`. Both are already on in this repo. For
the plain manifests, the `*-networkpolicies.yaml` file in each step does the same.

The policies only add **ingress** allow-rules for the platform's own pods:

| Into | From | Port |
|---|---|---|
| istiod (`istio-system`) | gateway pods; namespaces labelled `istio-injection=enabled` or `istio.io/rev` | 15012 (config, certificates) |
| istiod | API server (host network) | 15017 (injection and validation webhooks) |
| gateway pods (`api-gateway`) | anywhere (clients via the LoadBalancer) | 80, 443 |
| Authorino, Limitador (`kuadrant-system`) | gateway pods | 50051, 8081 |
| `kuadrant-system`, `servicemesh-operator`, `external-secrets` | API server (host network) | any (operator webhooks) |
| `kuadrant-system` | `openshift-console` | any (console plugin) |
| all of the above | same namespace; cluster monitoring | any |

**What isn't covered**
- **`istio-cni`** needs no policy. No traffic is ever sent to it: it configures each pod's network locally on the node.
- **App namespaces** need their own rule allowing the gateway's pods to reach the app's container port. `examples/*/60-networkpolicy.yaml` shows how.
- **AdminNetworkPolicy.** If your isolation comes from an AdminNetworkPolicy with a `Deny` action, NetworkPolicies cannot override it. Your cluster admin has to add an exception (an ANP rule with `Allow` or `Pass`) for the flows above.

**If you also restrict egress**, these flows need allowing from the source namespace:

| From | To | Port |
|---|---|---|
| gateway pods, sidecars | istiod | 15012 |
| gateway pods | Authorino, Limitador | 50051, 8081 |
| gateway pods | your backends | their container ports |
| gateway pods | the registry hosting Kuadrant's Wasm module (`registry.redhat.io` or your mirror) | 443 |
| istiod, operators, Authorino, External Secrets, istio-cni | API server | 6443 |
| Authorino | your OIDC provider | 443 |
| External Secrets | Vault | 8200 |
| everything | OpenShift DNS | 5353 (UDP and TCP) |

**Finding what's blocked**
- **The gateway can't reach istiod.** The gateway pod never becomes ready and logs connection errors to `istiod.istio-system.svc:15012`:

```bash
oc logs -n api-gateway deploy/api-gateway-istio | grep -i -m5 'istiod\|xds\|timeout'
```

- **The gateway can't reach Kuadrant.** Requests fail with `500`/`503`, and the gateway's log shows the Wasm filter failing to reach Authorino or Limitador.
- **To see which policies apply** in a namespace:

```bash
oc get networkpolicy -n istio-system
```

## Notes

- **Don't create** a GatewayClass with `controllerName: openshift.io/gateway-controller/v1`. That makes OpenShift install a second, gateway-only Istio that is not part of this mesh, and the ingress operator tries to subscribe to Service Mesh 3 in `openshift-operators`, which clashes with this repo's subscription.
- **Operator namespaces.** Nothing goes into `openshift-operators`:

| Operator | Namespace |
|---|---|
| Service Mesh 3 | `servicemesh-operator` (`serviceMesh.namespace`) |
| Connectivity Link | `kuadrant-system` |
| OpenShift GitOps | `openshift-gitops-operator` |
| External Secrets | `external-secrets` |

  If Service Mesh 3 is already installed in another namespace, delete that Subscription and CSV first. OLM allows only one copy of an operator per cluster.
- **Argo CD permissions.** The `openshift-gitops` instance gets cluster-admin because it installs operators and cluster-scoped resources. Give application teams their own namespace-scoped Argo CD instance, or limit them with AppProjects.
- **NetworkPolicies.** In namespaces that have them, allow ingress from `api-gateway`. The Istio sidecars also need to reach `istio-system`.
- **Pruning safety.** Subscriptions and namespaces carry `argocd.argoproj.io/sync-options: Delete=false`, so removing something from Git never uninstalls the operators or deletes a namespace.
- **Without Argo CD.** The charts in `charts/` still work with plain `helm upgrade --install` in wave order. Pass `site/*.yaml` and `apis/*/*.yaml` as values files, and label app namespaces with `istio-injection=enabled` and `api-gateway-access=true`.
- **Without Helm either.** [manifests/](manifests/README.md) has the whole platform as plain YAML in numbered steps, with `manifests/apply.sh` (needs only `oc`).
