# Troubleshooting: the gateway can't load Kuadrant's Wasm module

**Symptom.** Every request on every route fails with `503 wasm_fail_stream`, and the gateway logs:

```
createWasm: failed to load (cached) from http://kuadrant-operator-wasm.kuadrant-system.svc.cluster.local:8082/plugin.wasm
```

Each step below needs only `oc`, not the logs. Steps that use `oc exec` need exec rights in `api-gateway`.

## How the gateway loads the module

From Kuadrant 1.5, the operator serves its Wasm module over HTTP. The EnvoyFilter it writes for
each gateway (label `kuadrant.io/wasm=true`) tells Envoy to:

- download `http://kuadrant-operator-wasm.<operator namespace>.svc.cluster.local:8082/plugin.wasm`
  through its own Envoy cluster, `kuadrant-operator-wasm`. That cluster connects in plain
  HTTP/2, has a 1-second connect timeout, and resolves the full `.svc.cluster.local` name;
  it doesn't go through Istio's normal routing;
- accept the file only if its sha256 matches the one in the EnvoyFilter. A mismatch counts as a
  failed download.

**`(cached)`** means a download failed less than 10 seconds earlier, so Envoy reuses that failure
instead of trying again. Envoy creates no filter, and the Wasm filter fails closed, so every request
gets a 503.

**Recovery needs a restart.** Envoy downloads the module only when the gateway gets new config,
at startup or on a config push. After you fix the cause, restart the gateway:

```bash
oc rollout restart deployment/api-gateway-istio -n api-gateway
```

**Download counters.** Envoy's `remote_load_fetch_*` counters reset when the pod restarts:

```bash
oc exec -n api-gateway deploy/api-gateway-istio -- pilot-agent request GET stats | grep remote_load_fetch
```

On a pod that started after the fix, `remote_load_fetch_failures` means the download still fails.
`remote_load_fetch_successes: 1` with no failures means it works.

## 1. Is port 8082 allowed?

Only matters on clusters that restrict traffic between namespaces
(`networkPolicies.enabled: true`):

```bash
oc get networkpolicy rhcl-kuadrant-from-gateway -n kuadrant-system -o jsonpath='{.spec.ingress[0].ports[*].port}'
```

You should see `50051 8081 8082`. The policy covers every pod in `kuadrant-system`, and 8082 is the
operator pod's container port (`wasm`), not only the Service port.

## 2. Which step of the download fails?

Envoy keeps counters for the `kuadrant-operator-wasm` cluster. This needs no curl in the image:

```bash
oc exec -n api-gateway deploy/api-gateway-istio -- pilot-agent request GET stats | grep -E '^cluster\.kuadrant-operator-wasm\.(upstream_cx_(total|connect_fail|connect_timeout|destroy_remote)|upstream_rq_[0-9]xx|membership_total)'
```

| You see | Meaning | Next |
|---|---|---|
| `membership_total: 0` | The gateway can't resolve the hostname | Check that the Service exists: `oc get svc kuadrant-operator-wasm -n kuadrant-system` |
| `upstream_cx_connect_timeout` greater than 0 | Something drops the traffic | Look for another NetworkPolicy, an AdminNetworkPolicy, or a firewall between nodes |
| `upstream_cx_connect_fail` greater than 0, no timeouts | The connection is refused: nothing listens on 8082 | Step 3 |
| `upstream_rq_4xx` or `upstream_rq_5xx` | The server answers with an error instead of the file | Step 3 |
| `upstream_rq_2xx` greater than 0 | The download works, but the file doesn't match | Step 4 |

## 3. Is the Wasm server running?

```bash
oc get endpoints kuadrant-operator-wasm -n kuadrant-system
```

No addresses means the operator pod isn't ready. If it is ready but the connection is refused, the
Wasm server didn't start: the operator skips it when `/wasm/plugin.wasm` is missing from its image.
Its log says `wasm file not found, server will not start`.

## 4. Does the sha256 match?

The checksum the gateway expects. This needs no exec rights:

```bash
oc get envoyfilter -n api-gateway -l kuadrant.io/wasm=true -o jsonpath='{range .items[*].spec.configPatches[*]}{.patch.value.typed_config.value.config.vm_config.code.remote.sha256}{"\n"}{end}'
```

- **Empty:** the operator wrote the EnvoyFilter before its Wasm server had computed the checksum.
  Restart the operator, then the gateway:

  ```bash
  oc rollout restart deployment/kuadrant-operator-controller-manager -n kuadrant-system
  ```

- **A value:** compare it with the checksum of the file the gateway downloads. This needs curl in
  the gateway image:

  ```bash
  oc exec -n api-gateway deploy/api-gateway-istio -- sh -c 'curl -s http://kuadrant-operator-wasm.kuadrant-system.svc.cluster.local:8082/plugin.wasm | sha256sum'
  ```

## 5. Restart the gateway

After fixing the cause, restart the gateway (see "Recovery needs a restart" above). Then check that
`remote_load_fetch_failures` stays at 0.
