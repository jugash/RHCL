#!/usr/bin/env bash
# One-time manual step. Everything after this is driven from Git.
#   REPO_URL=https://github.com/<org>/<repo>.git [REVISION=main] [GITHUB_TOKEN=...] [YES=1] bootstrap/bootstrap.sh
# GITHUB_TOKEN is only needed for a private repo: a fine-grained token with read access to contents.
set -euo pipefail
cd "$(dirname "$0")"

: "${REPO_URL:?set REPO_URL to the GitHub repo, e.g. https://github.com/acme/rhcl-gitops.git}"
REVISION=${REVISION:-main}

# Preflight: make sure we are pointed at the intended OpenShift cluster, with enough rights.
die() { echo "ERROR: $*" >&2; exit 1; }
server=$(oc whoami --show-server 2>/dev/null) || die "no current oc context"
oc whoami >/dev/null 2>&1 || die "cannot reach $server as a logged-in user. Run: oc login <api-url>"
version=$(oc get clusterversion version -o jsonpath='{.status.desired.version}' 2>/dev/null) \
  || die "$server is not an OpenShift cluster (no ClusterVersion), or you cannot read it"
IFS=. read -r major minor _ <<<"$version"
(( major > 4 || (major == 4 && minor >= 19) )) || die "OpenShift $version found; 4.19 or newer is required"
[[ $(oc auth can-i '*' '*' --all-namespaces 2>/dev/null) == yes ]] \
  || die "$(oc whoami) is not cluster-admin on $server (installing operators needs it)"

echo "Cluster:  $server (OpenShift $version)"
echo "User:     $(oc whoami)"
echo "Repo:     $REPO_URL @ $REVISION"
if [[ -z "${YES:-}" ]]; then
  read -r -p "Install OpenShift GitOps and hand this cluster to the repo? [y/N] " answer
  [[ $answer == [yY]* ]] || die "aborted"
fi

echo "Installing OpenShift GitOps..."
oc apply -f gitops-operator.yaml
until oc get argocd openshift-gitops -n openshift-gitops >/dev/null 2>&1; do sleep 10; done
oc wait argocd/openshift-gitops -n openshift-gitops --for=jsonpath='{.status.phase}'=Available --timeout=10m

echo "Configuring Argo CD..."
oc apply -f argocd-rbac.yaml
oc patch argocd openshift-gitops -n openshift-gitops --type merge --patch-file argocd-health-checks.yaml

if [[ -n "${GITHUB_TOKEN:-}" ]]; then
  oc create secret generic rhcl-repo -n openshift-gitops \
    --from-literal=type=git --from-literal=url="$REPO_URL" \
    --from-literal=username=git --from-literal=password="$GITHUB_TOKEN" \
    --dry-run=client -o yaml \
  | oc label --local -f - argocd.argoproj.io/secret-type=repository -o yaml \
  | oc apply -f -
fi

echo "Creating the root Application..."
sed -e "s|\${REPO_URL}|$REPO_URL|g" -e "s|\${REVISION}|$REVISION|g" root-app.yaml | oc apply -f -

echo "Argo CD UI: https://$(oc get route openshift-gitops-server -n openshift-gitops -o jsonpath='{.spec.host}')"
