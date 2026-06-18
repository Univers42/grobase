{{/*
Shared helpers. Per-service resources are named "<release>-<service>"; common
labels follow the Kubernetes recommended label set so the whole edition is
selectable as one app, and each service as a component.
*/}}

{{- define "mini-baas.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "mini-baas.commonLabels" -}}
app.kubernetes.io/part-of: mini-baas
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ include "mini-baas.chart" . }}
mini-baas.io/edition: {{ .Values.edition | default "lean" | quote }}
{{- end -}}

{{/* selectorLabels: pass a dict {root, name} */}}
{{- define "mini-baas.selectorLabels" -}}
app.kubernetes.io/name: mini-baas
app.kubernetes.io/instance: {{ .root.Release.Name }}
app.kubernetes.io/component: {{ .name }}
{{- end -}}

{{/*
namespace: the namespace every object is pinned to, so the chart never lands in
`default` (Checkov CKV_K8S_21). Precedence:
  1. an explicit .Values.namespace (pin it: `--set namespace=…`)
  2. the install namespace .Release.Namespace when it is set to anything but
     "default" (the normal `helm install --namespace <ns>` path)
  3. the safe fallback .Values.namespaceDefault ("mini-baas") — never "default".
This means a bare `helm install`/`helm template` (which leaves .Release.Namespace
= "default") still renders a dedicated namespace instead of the cluster default.
*/}}
{{- define "mini-baas.namespace" -}}
{{- $fallback := .Values.namespaceDefault | default "mini-baas" -}}
{{- if .Values.namespace -}}
{{- .Values.namespace -}}
{{- else if and .Release.Namespace (ne .Release.Namespace "default") -}}
{{- .Release.Namespace -}}
{{- else -}}
{{- $fallback -}}
{{- end -}}
{{- end -}}

{{/*
fromServices: render NetworkPolicy ingress `from:` entries that allow traffic
from a set of release services (by component label). Pass {rel, components}.
*/}}
{{- define "mini-baas.fromServices" -}}
{{- $rel := .rel -}}
{{- range .components }}
- podSelector:
    matchLabels:
      app.kubernetes.io/name: mini-baas
      app.kubernetes.io/instance: {{ $rel }}
      app.kubernetes.io/component: {{ . }}
{{- end }}
{{- end -}}
