Test APIs as plain Kubernetes manifests. Each `examples/<namespace>/` folder is self-contained.
Files are numbered so `oc apply -f <folder>` creates the namespace first:

| File | What it is |
|---|---|
| `00-namespace.yaml` | A new namespace, labelled for the Istio sidecar and for attaching to the gateway |
| `10-app.yaml` | Echo backend (Deployment + Service) that replies with the request it received |
| `20-httproute.yaml` | Gateway API route on the shared gateway's HTTPS listener |
| `30-authpolicy.yaml` | Kuadrant AuthPolicy (who may call) |
| `40-ratelimitpolicy.yaml` | Kuadrant RateLimitPolicy (how often) |
| `50-externalsecrets.yaml` | API keys synced from Vault into `kuadrant-system` |

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

**Testing them**

`scripts/test-examples.sh` runs the expectations above against the gateway IP, with no DNS needed.
