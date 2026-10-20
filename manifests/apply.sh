#!/usr/bin/env bash
# Install the platform from the plain manifests in this folder, with oc only (no Helm, no Argo CD).
# Applies each numbered step and waits until it is ready before the next one.
#
#   manifests/apply.sh            # all steps
#   manifests/apply.sh 02 03      # only these steps (e.g. to re-apply after an edit)
#
# YES=1 skips the confirmation prompt.
set -euo pipefail
cd "$(dirname "$0")"

die() { echo "ERROR: $*" >&2; exit 1; }

# --- preflight: right cluster, right version, enough rights ---------------------------------
server=$(oc whoami --show-server 2>/dev/null) || die "no current oc context"
oc whoami >/dev/null 2>&1 || die "cannot reach $server as a logged-in user. Run: oc login <api-url>"
version=$(oc get clusterversion version -o jsonpath='{.status.desired.version}' 2>/dev/null) \
  || die "$server is not an OpenShift cluster (no ClusterVersion), or you cannot read it"
IFS=. read -r major minor _ <<<"$version"
(( major > 4 || (major == 4 && minor >= 19) )) || die "OpenShift $version found; 4.19 or newer is required"
[[ $(oc auth can-i '*' '*' --all-namespaces 2>/dev/null) == yes ]] \
  || die "$(oc whoami) is not cluster-admin on $server (installing operators needs it)"

steps=("$@")
[[ ${#steps[@]} -gt 0 ]] || steps=(01 02 03 04 05)

echo "Cluster: $server (OpenShift $version)"
echo "User:    $(oc whoami)"
echo "Steps:   ${steps[*]}"
if [[ -z "${YES:-}" ]]; then
  read -r -p "Apply these manifests to this cluster? [y/N] " answer
  [[ $answer == [yY]* ]] || die "aborted"
fi

# --- helpers ---------------------------------------------------------------------------------
# Wait for an OLM Subscription to install its CSV, then for the CSV to succeed.
wait_operator() {
  local ns=$1 sub=$2 csv="" i
  echo "  waiting for operator $sub..."
  for i in $(seq 1 90); do
    csv=$(oc get subscription "$sub" -n "$ns" -o jsonpath='{.status.installedCSV}' 2>/dev/null || true)
    [[ -n "$csv" ]] && break
    sleep 10
  done
  [[ -n "$csv" ]] || die "Subscription $ns/$sub has no installed CSV after 15 minutes (check: oc get installplan -n $ns)"
  oc wait csv/"$csv" -n "$ns" --for=jsonpath='{.status.phase}'=Succeeded --timeout=10m
}

# Wait for a resource to exist (CRs created by operators), then for a condition.
wait_for() {
  local what=$1 cond=$2 ns=${3:-} i
  echo "  waiting for $what ($cond)..."
  for i in $(seq 1 60); do
    oc get "$what" ${ns:+-n "$ns"} >/dev/null 2>&1 && break
    sleep 5
  done
  oc wait "$what" ${ns:+-n "$ns"} --for=condition="$cond" --timeout=10m
}

step() {
  case $1 in
    01)
      echo "== 01 operators"
      oc apply -f 01-operators/
      wait_operator servicemesh-operator servicemeshoperator3
      wait_operator kuadrant-system rhcl-operator
      ;;
    02)
      echo "== 02 mesh"
      oc apply -f 02-mesh/
      wait_for istiocni/default Ready
      wait_for istio/default Ready
      wait_for gatewayclass/istio Accepted
      ;;
    03)
      echo "== 03 kuadrant"
      oc apply -f 03-kuadrant/
      wait_for kuadrant/kuadrant Ready kuadrant-system
      ;;
    04)
      echo "== 04 gateway"
      oc apply -f 04-gateway/
      wait_for gateway/api-gateway Programmed api-gateway
      for p in tlspolicy/api-gateway-tls authpolicy/api-gateway-default-deny ratelimitpolicy/api-gateway-default-limit; do
        wait_for "$p" Accepted api-gateway
      done
      echo "  gateway address: $(oc get gateway api-gateway -n api-gateway -o jsonpath='{.status.addresses[0].value}')"
      ;;
    05)
      echo "== 05 vault store"
      if ! oc get crd clustersecretstores.external-secrets.io >/dev/null 2>&1; then
        echo "  skipped: External Secrets Operator is not installed (needed only for API keys from Vault)"
        return
      fi
      oc apply -f 05-vault-store/
      wait_for clustersecretstore/vault Ready
      ;;
    *) die "unknown step $1 (use 01-05)" ;;
  esac
}

for s in "${steps[@]}"; do step "$s"; done
echo "Done. Check everything with: scripts/verify.sh"
