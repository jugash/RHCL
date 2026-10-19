{{/* All HTTPS listeners: the main wildcard listener first, then extraListeners. */}}
{{- define "platform.httpsListeners" -}}
{{- $main := dict "name" "https" "hostname" .Values.gateway.hostname -}}
{{- prepend .Values.gateway.extraListeners $main | toYaml -}}
{{- end -}}

{{- define "platform.gatewayRef" -}}
group: gateway.networking.k8s.io
kind: Gateway
name: {{ .Values.gateway.name }}
{{- end -}}
