{{- define "api.name" -}}
{{- default .Release.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "api.routeRef" -}}
group: gateway.networking.k8s.io
kind: HTTPRoute
name: {{ include "api.name" . }}
{{- end -}}

{{- define "api.validate" -}}
{{- if not (has .Values.auth.mode (list "protected" "public" "none")) -}}
{{- fail "auth.mode must be one of: protected, public, none" -}}
{{- end -}}
{{- if and (eq .Values.auth.mode "protected") (not .Values.auth.apiKey.enabled) (not .Values.auth.oidc.enabled) -}}
{{- fail "auth.mode=protected needs auth.apiKey.enabled and/or auth.oidc.enabled" -}}
{{- end -}}
{{- if not .Values.hostnames -}}
{{- fail "hostnames must list at least one hostname" -}}
{{- end -}}
{{- if and (not .Values.rules) (not .Values.demo.enabled) -}}
{{- fail "rules must not be empty (or set demo.enabled=true)" -}}
{{- end -}}
{{- end -}}
