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

{{/*
Generic allow-rules for one platform namespace. Pass a dict: ns, and booleans hostNetwork, console.
Same-namespace and monitoring traffic are always allowed.
*/}}
{{- define "platform.np.common" -}}
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: rhcl-allow-same-namespace
  namespace: {{ .ns }}
spec:
  podSelector: {}
  policyTypes:
    - Ingress
  ingress:
    - from:
        - podSelector: {}
---
# Prometheus (cluster and user-workload monitoring) scrapes metrics.
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: rhcl-allow-from-monitoring
  namespace: {{ .ns }}
spec:
  podSelector: {}
  policyTypes:
    - Ingress
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              network.openshift.io/policy-group: monitoring
{{- if .hostNetwork }}
---
# The API server (host network) calls operator webhooks.
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: rhcl-allow-from-host-network
  namespace: {{ .ns }}
spec:
  podSelector: {}
  policyTypes:
    - Ingress
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              policy-group.network.openshift.io/host-network: ""
{{- end }}
{{- if .console }}
---
# The OpenShift console loads the Connectivity Link console plugin.
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: rhcl-allow-from-console
  namespace: {{ .ns }}
spec:
  podSelector: {}
  policyTypes:
    - Ingress
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: openshift-console
{{- end }}
{{- end -}}

{{/* Peer matching the shared gateway's pods. */}}
{{- define "platform.np.gatewayPeer" -}}
- namespaceSelector:
    matchLabels:
      kubernetes.io/metadata.name: {{ .Values.gateway.namespace }}
  podSelector:
    matchLabels:
      gateway.networking.k8s.io/gateway-name: {{ .Values.gateway.name }}
{{- end -}}
