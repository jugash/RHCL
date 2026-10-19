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
