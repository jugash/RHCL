Test APIs as plain Kubernetes manifests. Each `examples/<namespace>/` folder is self-contained.
Files are numbered so `oc apply -f <folder>` creates the namespace first:

| File | What it is |
|---|---|
| `00-namespace.yaml` | A new namespace, labelled for the Istio sidecar and for attaching to the gateway |
| `10-app.yaml` | nginx backend (ConfigMap + Deployment + Service) that replies with the request it received; runs as non-root on 8080 |
| `20-httproute.yaml` | Gateway API route on the shared gateway's HTTPS listener |
| `30-authpolicy.yaml` | Kuadrant AuthPolicy (who may call) |
| `40-ratelimitpolicy.yaml` | Kuadrant RateLimitPolicy (how often) |
| `50-externalsecrets.yaml` | API keys synced from Vault into `kuadrant-system` |
| `60-networkpolicy.yaml` | Default deny, plus exceptions for the gateway's pods (app port) and the sidecar (istiod, DNS) |

| Folder | Shows | Expect |
|---|---|---|
| `rhcl-ex-public` (`hello`) | Anonymous access, route-wide limit of 5 requests / 10s | `200`, then `429` |
| `rhcl-ex-apikey` (`echo`) | API keys from Vault; per-caller limits by plan (free 3 / 10s, gold 10 / 10s) | `401` without a key; `200` with one; bob (free) hits `429`, alice (gold) doesn't |
| `rhcl-ex-locked` (`locked`) | A route with no AuthPolicy | `403` from the gateway's deny-all default |

The hostnames are `<name>.api.example.internal`. Change them in each `20-httproute.yaml` if your gateway
uses another domain. They must fall under `gateway.hostname` in `site/platform-values.yaml`.

**Deploying them**
- With GitOps, the `rhcl-examples` ApplicationSet deploys every folder.
- Set `examples.enabled: false` in `gitops/values.yaml` to remove them.
- Without Argo CD, apply a folder directly, for example:

```bash
oc apply -f examples/rhcl-ex-public/
```

**Network policies**

Each example namespace denies all traffic except:
- from the gateway's pods (label `gateway.networking.k8s.io/gateway-name: api-gateway`) to the app's container port, `8080`;
- from the sidecar to istiod (`15012`) and to DNS (`5353`).

A passing `scripts/test-examples.sh` therefore shows the gateway works with everything else locked down.

To see the deny side, call the app directly from a pod outside the gateway. The request should time out:

```bash
oc run np-probe -n default --rm -i --restart=Never --image=registry.access.redhat.com/ubi9/ubi-minimal -- curl -sS -m 5 http://hello.rhcl-ex-public.svc/
```

Copy `60-networkpolicy.yaml` into a real app's namespace with its own `app` label and container port.
If the app still has an OpenShift Route, also allow the router until the Route is deleted. That rule
is a `namespaceSelector` on the label `policy-group.network.openshift.io/ingress: ""`.

**Testing them**

`scripts/test-examples.sh` runs the expectations above against the gateway IP, with no DNS needed.
