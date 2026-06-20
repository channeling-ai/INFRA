{{- define "platform.labels" -}}
app.kubernetes.io/name: platform
app.kubernetes.io/managed-by: argocd
app.kubernetes.io/instance: {{ .Release.Name }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end }}

{{- define "platform.selectorLabels" -}}
app.kubernetes.io/name: platform
app.kubernetes.io/component: {{ .component }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}
