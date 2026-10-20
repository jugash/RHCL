Test APIs, one per `examples/<namespace>/<name>.yaml`, deployed by the `rhcl-examples` ApplicationSet.

- Each runs in its own new `rhcl-ex-*` namespace with a small echo backend, so nothing existing is touched.
- Each is served at `<name>.<examples.domain>` (see `gitops/values.yaml`). No DNS record is needed,
  because `scripts/test-examples.sh` talks to the gateway IP directly.
- Remove them all by setting `examples.enabled: false` in `gitops/values.yaml`.

| File | Shows |
|---|---|
| `rhcl-ex-public/hello.yaml` | Anonymous access, route-wide rate limit (5 requests / 10s) |
| `rhcl-ex-apikey/echo.yaml` | API keys from Vault, per-user limits by plan (free 3 / 10s, gold 10 / 10s) |
| `rhcl-ex-locked/locked.yaml` | A route without an AuthPolicy is denied by the gateway default |
