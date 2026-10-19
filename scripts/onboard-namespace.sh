#!/usr/bin/env bash
# Prepare a namespace for the mesh and the API gateway.
#   onboard-namespace.sh <namespace> [--restart] [--no-mesh]
# --restart  roll out existing Deployments/StatefulSets so they get the Istio sidecar
# --no-mesh  only allow gateway attachment, no sidecar injection
set -euo pipefail

ns=${1:?usage: $0 <namespace> [--restart] [--no-mesh]}
shift
restart=false mesh=true
for arg in "$@"; do
  case $arg in
    --restart) restart=true ;;
    --no-mesh) mesh=false ;;
    *) echo "unknown option: $arg" >&2; exit 1 ;;
  esac
done

oc get namespace "$ns" >/dev/null 2>&1 || oc create namespace "$ns"
oc label namespace "$ns" api-gateway-access=true --overwrite
if $mesh; then
  oc label namespace "$ns" istio-injection=enabled --overwrite
fi

if $restart && $mesh; then
  oc rollout restart deployment,statefulset -n "$ns"
fi

cat <<MSG
Namespace $ns is labelled for the gateway$($mesh && echo " and the mesh").
If it has NetworkPolicies, allow ingress from namespace api-gateway (and istio-system for the mesh).
MSG
