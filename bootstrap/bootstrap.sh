#!/usr/bin/env bash
# One-time manual step. Everything after this is driven from Git.
#   REPO_URL=https://github.com/<org>/<repo>.git [REVISION=main] [GITHUB_TOKEN=...] bootstrap/bootstrap.sh
# GITHUB_TOKEN is only needed for a private repo: a fine-grained token with read access to contents.
set -euo pipefail
cd "$(dirname "$0")"

: "${REPO_URL:?set REPO_URL to the GitHub repo, e.g. https://github.com/acme/rhcl-gitops.git}"
REVISION=${REVISION:-main}

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
