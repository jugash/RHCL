# Platform as plain manifests

The same platform the Helm charts install, as plain Kubernetes YAML: for clusters where you
can't use Helm or Argo CD. Everything is applied with `oc`.

| Step | Folder | Creates | Ready when |
|---|---|---|---|
| 01 | `01-operators/` | Service Mesh 3 operator (`servicemesh-operator`), Connectivity Link operator (`kuadrant-system`) | both CSVs `Succeeded` |
| 02 | `02-mesh/` | IstioCNI, Istio control plane, mesh-wide mTLS mode | Istio `Ready`, GatewayClass `istio` accepted |
| 03 | `03-kuadrant/` | Kuadrant (Authorino, Limitador, policy controllers) | Kuadrant `Ready` |
| 04 | `04-gateway/` | Shared gateway, TLSPolicy, HTTP→HTTPS redirect, default deny and default rate limit | Gateway `Programmed` |
| 05 | `05-vault-store/` | ClusterSecretStore for API keys in Vault | store `Ready` (skipped without External Secrets) |

Each step needs the CRDs from the step before it, so apply them in order and wait in between.

The `*-networkpolicies.yaml` files add ingress allow-rules for clusters whose NetworkPolicies restrict
traffic between namespaces (see "Clusters that restrict traffic between namespaces" in the main README).
Delete them if your cluster has no such restrictions.

## Before applying

Edit the lines marked `EDIT`:

| File | Set |
|---|---|
| `04-gateway/10-gateway.yaml` | `hostname` of the `https` listener (your API domain); optionally pin the LoadBalancer IP |
| `04-gateway/20-tlspolicy.yaml` | `issuerRef.name`: your cert-manager ClusterIssuer |
| `05-vault-store/30-clustersecretstore.yaml` | `server`: your Vault URL |

Prerequisites:

- OpenShift 4.19+ and cluster-admin.
- cert-manager with a ClusterIssuer.
- A LoadBalancer provider (e.g. MetalLB).
- For step 05 only: External Secrets Operator, installed from OperatorHub or by your platform team. Its controller ServiceAccount must be `external-secrets/external-secrets`, or you edit `05-vault-store/` to match. Vault itself is configured with `vault/setup.sh`.

## Apply

The script runs the same preflight checks as the bootstrap (OpenShift 4.19+, cluster-admin, confirmation), then applies each step and waits for it:

```bash
manifests/apply.sh
```

Re-apply only some steps after editing:

```bash
manifests/apply.sh 04
```

Or do it by hand, one step at a time:

```bash
oc apply -f manifests/01-operators/
```

```bash
oc get csv -n servicemesh-operator -w
```

```bash
oc get csv -n kuadrant-system -w
```

```bash
oc apply -f manifests/02-mesh/ && oc wait istio/default --for=condition=Ready --timeout=10m
```

```bash
oc apply -f manifests/03-kuadrant/ && oc wait kuadrant/kuadrant -n kuadrant-system --for=condition=Ready --timeout=10m
```

```bash
oc apply -f manifests/04-gateway/ && oc wait gateway/api-gateway -n api-gateway --for=condition=Programmed --timeout=10m
```

```bash
oc apply -f manifests/05-vault-store/
```

## Then

- `scripts/verify.sh` checks every layer and prints the gateway address for your DNS record.
- The test APIs in `examples/` are plain manifests too:

```bash
oc apply -f examples/rhcl-ex-public/
```

```bash
scripts/test-examples.sh
```

## Optional

| File | Use |
|---|---|
| `optional/apikey-secret.yaml` | An API key as a plain Secret, for clusters without Vault / External Secrets |
| `optional/authorino-trust-internal-ca.yaml` | OIDC with an IdP behind an internal CA: declares the Authorino CR with the cluster CA bundle mounted |

`apply.sh` doesn't apply either; each file explains how to use it.

## Keeping in sync with the charts

These files are the charts rendered with `site/*.yaml`, with Helm/Argo-only annotations removed
and comments added. If you change a chart or a site value, update the matching file here too.
