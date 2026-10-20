#!/usr/bin/env bash
# End-to-end tests for the APIs in examples/. Read-only: it sends HTTP requests to the gateway's
# own IP (no DNS needed) and reads cluster objects. It changes nothing.
#
#   scripts/test-examples.sh
#
# Optional environment:
#   EXISTING_URLS  space-separated URLs of your current Routes/Ingresses, checked to still respond
#   CACERT         CA file to verify the gateway certificate (default: skip verification, -k)
#   TOKEN          an OIDC access token, to test Bearer auth on echo (needs oidc.enabled in the example)
#   GW_NS, GW_NAME gateway namespace and name (default: api-gateway / api-gateway)
set -uo pipefail
cd "$(dirname "$0")/.."

gw_ns=${GW_NS:-api-gateway}
gw=${GW_NAME:-api-gateway}
tls=(-k)
[[ -n "${CACERT:-}" ]] && tls=(--cacert "$CACERT")

pass=0 fail=0 skip=0
ok()   { printf '  PASS  %s\n' "$1"; pass=$((pass + 1)); }
ko()   { printf '  FAIL  %s\n' "$1"; fail=$((fail + 1)); }
sk()   { printf '  SKIP  %s\n' "$1"; skip=$((skip + 1)); }
expect() { if [[ $3 == "$2" ]]; then ok "$1 ($3)"; else ko "$1: expected $2, got $3"; fi; }

# code <host> <path> [curl args...] -> HTTP status through the gateway
code() {
  local host=$1 path=$2; shift 2
  curl -sS -o /dev/null -w '%{http_code}' --max-time 10 "${tls[@]}" \
    --resolve "$host:443:$ip" "https://$host$path" "$@" 2>/dev/null || echo "000"
}
body() {
  local host=$1 path=$2; shift 2
  curl -sS --max-time 10 "${tls[@]}" --resolve "$host:443:$ip" "https://$host$path" "$@" 2>/dev/null
}
# burst <n> <host> [curl args...] -> status codes of n quick requests
burst() {
  local n=$1 host=$2; shift 2
  for _ in $(seq 1 "$n"); do printf '%s ' "$(code "$host" / "$@")"; done
}
# Let all 10s rate-limit windows expire before the next limit test.
reset_limits() { sleep 11; }

# Hostnames come from the deployed HTTPRoutes, so editing them in examples/ is enough.
host_of() { oc get httproute "$1" -n "$2" -o jsonpath='{.spec.hostnames[0]}' 2>/dev/null; }
hello=$(host_of hello rhcl-ex-public)
echo_host=$(host_of echo rhcl-ex-apikey)
locked=$(host_of locked rhcl-ex-locked)
if [[ -z "$hello" || -z "$echo_host" || -z "$locked" ]]; then
  echo "Example HTTPRoutes not found. Check: oc get applications -n openshift-gitops | grep example-"
  exit 1
fi

echo "Gateway $gw_ns/$gw"
ip=$(oc get gateway "$gw" -n "$gw_ns" -o jsonpath='{.status.addresses[0].value}' 2>/dev/null)
[[ -n "$ip" ]] || { echo "  The gateway has no address yet. Run scripts/verify.sh first."; exit 1; }
echo "  address: $ip"

echo
echo "TLS and redirect"
cert=$(openssl s_client -connect "$ip:443" -servername "$hello" </dev/null 2>/dev/null \
  | openssl x509 -noout -subject -issuer -enddate 2>/dev/null)
if [[ -n "$cert" ]]; then ok "certificate served for $hello"; sed 's/^/        /' <<<"$cert"; else ko "no certificate for $hello"; fi
redirect=$(curl -sS -o /dev/null -w '%{http_code} %{redirect_url}' --max-time 10 \
  --resolve "$hello:80:$ip" "http://$hello/" 2>/dev/null)
if [[ $redirect == 301\ https://* ]]; then ok "HTTP redirects to HTTPS ($redirect)"; else ko "HTTP redirect: got '$redirect'"; fi

echo
echo "Public API ($hello)"
expect "anonymous request" 200 "$(code "$hello" /)"
reset_limits
codes=$(burst 8 "$hello")
if [[ $codes == *429* ]]; then ok "route limit 5/10s enforced: $codes"; else ko "no 429 in 8 requests: $codes"; fi

echo
echo "Default deny ($locked)"
expect "route without AuthPolicy" 403 "$(code "$locked" /)"
# Capture first: with pipefail, `curl | grep -q` can fail when grep exits early.
deny_body=$(body "$locked" /)
if grep -q "no AuthPolicy" <<<"$deny_body"; then ok "deny message from gateway default"; else ko "unexpected 403 body"; fi

echo
echo "API keys ($echo_host)"
key() { oc get secret "apikey-echo-$1" -n kuadrant-system -o jsonpath='{.data.api_key}' 2>/dev/null | base64 -d 2>/dev/null; }
alice=$(key alice) bob=$(key bob)
expect "no credentials" 401 "$(code "$echo_host" /)"
expect "wrong key" 401 "$(code "$echo_host" / -H 'Authorization: APIKEY not-a-real-key')"
if [[ -z "$alice" || -z "$bob" ]]; then
  sk "keys for alice/bob not synced yet. Create them, then wait for the ExternalSecrets:"
  echo "        scripts/vault-create-api-key.sh echo alice && scripts/vault-create-api-key.sh echo bob"
  echo "        oc get externalsecret -n kuadrant-system"
else
  reset_limits
  expect "alice (gold)" 200 "$(code "$echo_host" / -H "Authorization: APIKEY $alice")"
  expect "bob (free)" 200 "$(code "$echo_host" / -H "Authorization: APIKEY $bob")"
  reset_limits
  codes=$(burst 6 "$echo_host" -H "Authorization: APIKEY $bob")
  if [[ $codes == *429* ]]; then ok "bob's free limit 3/10s enforced: $codes"; else ko "no 429 for bob in 6 requests: $codes"; fi
  expect "alice unaffected by bob's limit" 200 "$(code "$echo_host" / -H "Authorization: APIKEY $alice")"

  # The nginx backend echoes the X-Forwarded-Client-Cert header it received. The sidecar adds
  # X-Forwarded-Client-Cert with the gateway's SPIFFE identity when the hop was mutual TLS.
  echo_body=$(body "$echo_host" / -H "Authorization: APIKEY $alice")
  if grep -qi 'x-forwarded-client-cert.*spiffe://' <<<"$echo_body"; then
    ok "gateway -> app traffic is mutual TLS (XFCC header carries a SPIFFE identity)"
  else
    sk "could not confirm mTLS from the echo response; check the pods have an istio-proxy container"
  fi
fi
if [[ -n "${TOKEN:-}" ]]; then
  expect "OIDC bearer token" 200 "$(code "$echo_host" / -H "Authorization: Bearer $TOKEN")"
fi

echo
echo "Mesh"
for ns in $(ls -d examples/*/ | xargs -n1 basename); do
  containers=$(oc get pods -n "$ns" -o jsonpath='{range .items[*]}{.spec.containers[*].name} {.spec.initContainers[*].name}{"\n"}{end}' 2>/dev/null)
  if [[ -z "$containers" ]]; then ko "$ns: no pods"
  elif grep -qv istio-proxy <<<"$containers"; then ko "$ns: some pods have no istio-proxy sidecar"
  else ok "$ns: pods have the istio-proxy sidecar"; fi
done

echo
echo "Network policies"
# The API tests above already went through these policies; here we check they are all in place,
# so a pass means "reachable from the gateway with everything else denied".
for ns in $(ls -d examples/*/ | xargs -n1 basename); do
  have=$(oc get networkpolicy -n "$ns" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)
  missing=""
  for np in default-deny allow-from-api-gateway allow-mesh-egress; do
    [[ " $have " == *" $np "* ]] || missing+=" $np"
  done
  if [[ -z "$missing" ]]; then ok "$ns: default-deny with gateway and mesh exceptions"
  else ko "$ns: missing NetworkPolicies:$missing"; fi
done

echo
echo "No impact on the existing setup"
expected=$( (ls -d examples/*/ apis/*/ 2>/dev/null) | xargs -n1 basename | sort -u)
for label in istio-injection=enabled api-gateway-access=true; do
  others=$(oc get ns -l "$label" -o name 2>/dev/null | sed 's|namespace/||' | grep -vxF -f <(echo "$expected") || true)
  if [[ -z "$others" ]]; then ok "only repo namespaces carry $label"
  else sk "other namespaces carry $label (not set by this repo; check they are expected): $(echo $others)"; fi
done
others=$(oc get httproute -A --no-headers 2>/dev/null | awk '{print $1}' | sort -u \
  | grep -vxF -f <(printf '%s\n' "$expected" "$gw_ns") || true)
if [[ -z "$others" ]]; then ok "no HTTPRoutes outside repo namespaces"; else ko "HTTPRoutes in: $(echo $others)"; fi
router=$(oc get ingresscontroller default -n openshift-ingress-operator \
  -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null)
expect "default router (IngressController) available" True "$router"
for url in ${EXISTING_URLS:-}; do
  status=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 "${tls[@]}" "$url" 2>/dev/null || echo 000)
  if [[ $status =~ ^[23] ]]; then ok "existing $url ($status)"; else ko "existing $url returned $status"; fi
done
[[ -z "${EXISTING_URLS:-}" ]] && sk "set EXISTING_URLS to also check some of your current Routes respond"

echo
echo "$pass passed, $fail failed, $skip skipped"
exit $((fail > 0))
