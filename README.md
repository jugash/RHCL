# Red Hat Connectivity Link on OpenShift (on-prem)

Helm charts and scripts that set up:

- **OpenShift Service Mesh 3** in sidecar mode, with **one Istio control plane** for both the mesh and the API gateway.
  Because the gateway is in the mesh, traffic from the gateway to your apps is mutual TLS.
- **Connectivity Link (Kuadrant)**: Authorino for API keys and OIDC/JWT, Limitador for rate limits, and TLSPolicy for cert-manager certificates.
- A shared **Gateway API gateway** with safe defaults: every route is denied unless it has its own AuthPolicy, plus a default rate limit and an HTTP→HTTPS redirect.
- A path to **move apps off OpenShift Routes/Ingress** and onto HTTPRoutes.

Target: OpenShift 4.19+ on-prem, with MetalLB (or another LoadBalancer provider) and cert-manager already installed.

```
charts/
  rhcl-operators/   OLM subscriptions: servicemeshoperator3, rhcl-operator
  rhcl-platform/    IstioCNI, Istio, mTLS mode, Kuadrant, Gateway, TLSPolicy, default policies
  api/              one release per API: HTTPRoute + AuthPolicy + RateLimitPolicy (+ optional demo backend)
scripts/
  onboard-namespace.sh       label a namespace for the mesh and the gateway
  create-api-key.sh          create an API key for an API
  routes-to-api-values.py    turn existing Routes/Ingresses into api-chart values files
  verify.sh                  check each layer and report what is not ready
```

The work is split into three charts because Helm cannot create a resource before its CRD exists, and the operators from the first chart install the CRDs that the second chart uses.

## Values to change

| Where | Value | Default |
|---|---|---|
| `rhcl-platform` | `gateway.hostname`: wildcard domain for APIs | `*.api.example.internal` |
| `rhcl-platform` | `tls.issuer.name`: your cert-manager ClusterIssuer | `internal-ca` |
| `rhcl-platform` | `gateway.serviceAnnotations`: pin the LB IP so DNS stays valid | none |
| `api` | `auth.oidc.issuerUrl`: your IdP realm | `https://sso.example.internal/realms/api` |

Put site values in your own file (e.g. `site-values.yaml`) instead of editing the charts:

```yaml
# site-values.yaml (for rhcl-platform)
gateway:
  hostname: "*.api.corp.example"
  serviceAnnotations:
    metallb.io/loadBalancerIPs: 10.20.30.40
tls:
  issuer:
    name: corp-ca
```

## Install

You need `cluster-admin`.

### 1. Operators

```bash
helm upgrade --install rhcl-operators charts/rhcl-operators -n kuadrant-system --create-namespace
```

Wait until both operators report `Succeeded`. This takes a few minutes, and the next chart fails if you go on too early:

```bash
oc get csv -n openshift-operators -l operators.coreos.com/servicemeshoperator3.openshift-operators -w
```

```bash
oc get csv -n kuadrant-system -w
```

### 2. Platform (mesh, Kuadrant, gateway)

```bash
helm upgrade --install rhcl-platform charts/rhcl-platform -n kuadrant-system -f site-values.yaml
```

```bash
scripts/verify.sh
```

`verify.sh` checks operators → Istio → GatewayClass → Kuadrant → Gateway → policies, and prints the gateway's address.

Then pin the Istio version, so that a later operator upgrade doesn't silently upgrade the mesh:

```bash
oc get istio default -o jsonpath='{.spec.version}'
```

Set that value as `mesh.version` in `site-values.yaml`.

### 3. DNS (on-prem)

Kuadrant's DNSPolicy can't write to BIND, Infoblox or AD DNS, so DNS is a one-time manual step. In your DNS, create:

```
*.api.example.internal.   A   <gateway address from verify.sh>
```

Pin the address with `gateway.serviceAnnotations` (e.g. `metallb.io/loadBalancerIPs`) so this record stays valid.

### 4. Try it with the demo API

```bash
scripts/onboard-namespace.sh echo-api
```

```bash
helm upgrade --install echo-api charts/api -n echo-api -f charts/api/values-demo.yaml
```

```bash
KEY=$(scripts/create-api-key.sh echo-api alice gold)
```

Expected results:

```bash
curl -i https://echo.api.example.internal/
```

returns `401`: no credentials.

```bash
curl -i -H "Authorization: APIKEY $KEY" https://echo.api.example.internal/
```

returns `200`.

To see a rate limit, create a `free`-plan key (60 requests a minute):

```bash
FREE=$(scripts/create-api-key.sh echo-api bob free)
```

Call it 70 times. The last calls return `429`:

```bash
for i in $(seq 1 70); do curl -s -o /dev/null -w '%{http_code} ' -H "Authorization: APIKEY $FREE" https://echo.api.example.internal/; done
```

## Exposing an API

One `api` release per API, in the app's namespace:

```yaml
# orders-values.yaml
hostnames: [orders.api.example.internal]
rules:
  - matches: [{path: {type: PathPrefix, value: /}}]
    backendRefs: [{name: orders, port: 8080}]
auth:
  mode: protected        # protected | public | none
  apiKey: {enabled: true}
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

```bash
helm upgrade --install orders charts/api -n shop -f orders-values.yaml
```

How the pieces fit:

- **Auth.** Callers send either `Authorization: APIKEY <key>` or `Authorization: Bearer <jwt>`. Either one is enough.
- **Per-user limits.** The AuthPolicy publishes `auth.identity.userid` and `auth.identity.planid`. For an API key these come from the Secret annotations `secret.kuadrant.io/user-id` and `secret.kuadrant.io/plan-id`. For a JWT they come from `sub` and the `plan` claim (`auth.oidc.planClaim`). The RateLimitPolicy counts per `userid`, with a limit for each plan.
- **Unlisted plans.** A caller whose plan is not in `rateLimit.perUser.plans` gets only the route-wide `total` limit.
- **Revoking a key.** `oc delete secret apikey-<api>-<user> -n kuadrant-system`

### Trusting an internal CA for OIDC

Authorino fetches your IdP's discovery document and keys over HTTPS. If the IdP's certificate comes from an internal CA, Authorino must trust that CA.

1. Make sure the CA is in the cluster trust bundle (`oc get proxy cluster -o jsonpath='{.spec.trustedCA.name}'`).
2. Create a ConfigMap that OpenShift fills with that bundle:

```bash
oc create configmap internal-ca-bundle -n kuadrant-system
```

```bash
oc label configmap internal-ca-bundle -n kuadrant-system config.openshift.io/inject-trusted-cabundle=true
```

3. Mount it into Authorino:

```bash
oc patch authorino authorino -n kuadrant-system --type merge -p '{"spec":{"volumes":{"items":[{"name":"internal-ca","mountPath":"/etc/ssl/certs","configMaps":["internal-ca-bundle"],"items":[{"key":"ca-bundle.crt","path":"ca-bundle.crt"}]}]}}}'
```

After an operator upgrade, check that the patch is still in place: the Kuadrant operator manages this Authorino CR.

## Migrating off Routes/Ingress

The **default IngressController (router) stays**. It serves the web console, OAuth, monitoring and other `openshift-*` routes, and must not be removed. What you migrate is your applications' Routes and Ingresses. Once that is done, the router serves only the platform.

1. Export what you have and generate a plan:

```bash
oc get routes,ingresses,services -A -o json > cluster.json
```

```bash
scripts/routes-to-api-values.py cluster.json --out migration --gateway-hostname '*.api.example.internal'
```

   - Add `--rehost apps.ocp.example.internal=api.example.internal` to move apps to the new domain while you're at it.
   - Without it, hostnames stay the same, and the plan lists the extra gateway listeners they need.

2. Follow `migration/REPORT.md` step by step:
   1. **Onboard namespaces.** This adds the sidecar and gateway labels and restarts the pods. With `mtlsMode: PERMISSIVE`, the old Routes keep working.
   2. **Add listeners.** If the report lists `extraListeners`, add them to `site-values.yaml` and upgrade `rhcl-platform`.
   3. **Install the generated values files.** Each starts as `auth.mode: public` so behaviour doesn't change. Read the `WARNING` lines at the top of each file (IP allow-lists, custom certificates, reencrypt, etc.).
   4. **Test** through the gateway with `curl --resolve` before touching DNS.
   5. **Cut over DNS.**
      - New domain: nothing to do, the wildcard already points at the gateway.
      - Same hostname: add a specific A record for that hostname pointing at the gateway. It overrides the `*.apps` wildcard that points at the router.
   6. **Delete the old Route or Ingress.**
3. Tighten each API: switch `auth.mode` to `protected` once its callers have keys or tokens.
4. When no app traffic uses the router any more, set `mesh.mtlsMode: STRICT` and upgrade `rhcl-platform`.

Not converted automatically:

- **Passthrough Routes.** These need a TLSRoute and a passthrough listener.
- **Reencrypt Routes.** The app can serve plain HTTP inside the mesh, because the sidecars handle mTLS.
- **HAProxy annotations** other than `timeout`. For example, `ip_whitelist` becomes an AuthPolicy rule on `source.address`.

## Notes

- **Don't create** a GatewayClass with `controllerName: openshift.io/gateway-controller/v1`. That makes OpenShift install a second, gateway-only Istio that is not part of this mesh.
- **NetworkPolicies.** In namespaces that have them, allow ingress from `api-gateway`. The Istio sidecars also need to reach `istio-system`.
- **Upgrades.** For production, set `installPlanApproval: Manual` in `rhcl-operators`, and pin `mesh.version`.
- **Uninstall.** `helm uninstall` keeps the Subscriptions and Namespaces (`helm.sh/resource-policy: keep`), so a mistaken uninstall doesn't remove the operators or delete data.
