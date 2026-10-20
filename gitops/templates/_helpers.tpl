{{/* Pass a dict; optional key extraSyncOptions. */}}
{{- define "gitops.syncPolicy" -}}
automated:
  prune: true
  selfHeal: true
syncOptions:
  - CreateNamespace=true
  # Only diff the fields we set, so operator-defaulted fields don't show as drift.
  - ServerSideApply=true
  # CRDs from an earlier wave may still be registering.
  - SkipDryRunOnMissingResource=true
  {{- range .extraSyncOptions }}
  - {{ . }}
  {{- end }}
retry:
  limit: 10
  backoff:
    duration: 30s
    factor: 2
    maxDuration: 10m
{{- end -}}

{{- define "gitops.wave" -}}
argocd.argoproj.io/sync-wave: {{ . | quote }}
{{- end -}}

{{/*
ApplicationSet that turns <dir>/<namespace>/<name>.yaml files into charts/api releases.
Pass a dict: root (the chart context), name, dir, appPrefix, and optionally domain
(sets hostnames[0] to <name>.<domain> so the files don't need their own hostnames).
*/}}
{{- define "gitops.apiAppSet" -}}
{{- $v := .root.Values -}}
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: {{ .name }}
  namespace: {{ .root.Release.Namespace }}
  annotations:
    {{- include "gitops.wave" 2 | nindent 4 }}
spec:
  goTemplate: true
  goTemplateOptions: ["missingkey=error"]
  generators:
    - git:
        repoURL: {{ $v.repoURL }}
        revision: {{ $v.revision }}
        files:
          - path: {{ .dir }}/*/*.yaml
  template:
    metadata:
      name: '{{ .appPrefix }}-{{`{{ .path.basename }}-{{ trimSuffix ".yaml" .path.filename }}`}}'
    spec:
      project: rhcl
      source:
        repoURL: {{ $v.repoURL }}
        targetRevision: {{ $v.revision }}
        path: charts/api
        helm:
          releaseName: {{`'{{ trimSuffix ".yaml" .path.filename }}'`}}
          valueFiles:
            - {{`'../../{{ .path.path }}/{{ .path.filename }}'`}}
          {{- with .domain }}
          parameters:
            - name: hostnames[0]
              value: '{{`{{ trimSuffix ".yaml" .path.filename }}`}}.{{ . }}'
          {{- end }}
      destination:
        server: https://kubernetes.default.svc
        namespace: {{`'{{ .path.basename }}'`}}
      syncPolicy:
        {{- include "gitops.syncPolicy" dict | nindent 8 }}
        # Sidecar injection plus permission to attach to the gateway.
        # Existing pods only get a sidecar after a restart.
        managedNamespaceMetadata:
          labels:
            istio-injection: enabled
            api-gateway-access: "true"
{{- end -}}
