{{- define "monitoring.labels" -}}
app.kubernetes.io/name: monitoring
app.kubernetes.io/managed-by: argocd
app.kubernetes.io/instance: {{ .Release.Name }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end }}

{{- define "monitoring.selectorLabels" -}}
app.kubernetes.io/name: monitoring
app.kubernetes.io/component: {{ .component }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}
