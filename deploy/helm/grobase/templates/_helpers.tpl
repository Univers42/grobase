{{/*
Shared helpers for the PRODUCTION grobase chart.

Naming: resources are "<release>-<plane>"; the chart-wide label set follows the
Kubernetes recommended labels so the whole platform is selectable as one app,
and each plane as a component. Selector labels are the immutable subset
(name/instance/component) — never put a mutable field (version/edition) in a
selector or a rolling update on an existing release breaks.
*/}}

{{- define "grobase.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "grobase.commonLabels" -}}
app.kubernetes.io/part-of: grobase
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
helm.sh/chart: {{ include "grobase.chart" . }}
{{- end -}}

{{/* selectorLabels: pass a dict {root, name} — the IMMUTABLE selector subset */}}
{{- define "grobase.selectorLabels" -}}
app.kubernetes.io/name: grobase
app.kubernetes.io/instance: {{ .root.Release.Name }}
app.kubernetes.io/component: {{ .name }}
{{- end -}}

{{/*
image: resolve a plane's image. A plane may pin an explicit `image:`; otherwise
it falls back to the registry convention "<registry>/mini-baas-<plane>:<tag>"
(the same images the compose stack + the generated mini-baas chart use).
Pass a dict {root, name, plane}.
*/}}
{{- define "grobase.image" -}}
{{- $g := .root.Values.global -}}
{{- if .plane.image -}}
{{ .plane.image }}
{{- else -}}
{{ printf "%s/mini-baas-%s:%s" $g.imageRegistry (.plane.imageName | default .name) $g.imageTag }}
{{- end -}}
{{- end -}}

{{/*
fromPlanes: render NetworkPolicy ingress `from:` entries that allow traffic from
a set of release planes (by component label). Pass {rel, components}.
*/}}
{{- define "grobase.fromPlanes" -}}
{{- $rel := .rel -}}
{{- range .components }}
- podSelector:
    matchLabels:
      app.kubernetes.io/name: grobase
      app.kubernetes.io/instance: {{ $rel }}
      app.kubernetes.io/component: {{ . }}
{{- end }}
{{- end -}}
