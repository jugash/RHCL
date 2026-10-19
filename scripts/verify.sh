#!/usr/bin/env bash
# Check each layer of the install and report what is not ready yet.
#   verify.sh [gateway-namespace] [gateway-name]
# MESH_OPERATOR_NS overrides the Service Mesh operator namespace (serviceMesh.namespace in rhcl-operators).
set -uo pipefail

gw_ns=${1:-api-gateway}
gw=${2:-api-gateway}
mesh_ns=${MESH_OPERATOR_NS:-servicemesh-operator}
fail=0

check() {
  local desc=$1; shift
  if out=$("$@" 2>&1); then
    printf '  ok    %s\n' "$desc"
  else
    printf '  FAIL  %s\n        %s\n' "$desc" "$(echo "$out" | head -2)"
    fail=1
  fi
}

echo "Operators"
check "Service Mesh 3 operator" oc wait csv -n "$mesh_ns" -l operators.coreos.com/servicemeshoperator3."$mesh_ns" --for=jsonpath='{.status.phase}'=Succeeded --timeout=10s
check "Connectivity Link operator" oc wait csv -n kuadrant-system -l operators.coreos.com/rhcl-operator.kuadrant-system --for=jsonpath='{.status.phase}'=Succeeded --timeout=10s

echo "Mesh"
check "IstioCNI ready" oc wait istiocni/default --for=condition=Ready --timeout=10s
check "Istio ready" oc wait istio/default --for=condition=Ready --timeout=10s
check "GatewayClass istio accepted" oc wait gatewayclass/istio --for=condition=Accepted --timeout=10s

echo "Kuadrant"
check "Kuadrant ready" oc wait kuadrant/kuadrant -n kuadrant-system --for=condition=Ready --timeout=10s

echo "Gateway"
check "Gateway programmed" oc wait gateway/"$gw" -n "$gw_ns" --for=condition=Programmed --timeout=10s
for kind in tlspolicy authpolicy ratelimitpolicy; do
  for p in $(oc get "$kind" -n "$gw_ns" -o name 2>/dev/null); do
    check "$p enforced" oc wait "$p" -n "$gw_ns" --for=condition=Enforced --timeout=10s
  done
done
addr=$(oc get gateway "$gw" -n "$gw_ns" -o jsonpath='{.status.addresses[0].value}' 2>/dev/null)
echo "  gateway address: ${addr:-<none yet>}"

echo "Routes and policies outside the gateway namespace"
oc get httproute,authpolicy,ratelimitpolicy -A --no-headers 2>/dev/null | grep -v "^$gw_ns " || echo "  none"

exit $fail
