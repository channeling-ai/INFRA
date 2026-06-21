{{/*
공통 라벨
*/}}
{{- define "data.labels" -}}
app.kubernetes.io/name: data
app.kubernetes.io/managed-by: argocd
app.kubernetes.io/instance: {{ .Release.Name }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end }}

{{/*
selector 라벨 (component 인자 받음)
*/}}
{{- define "data.selectorLabels" -}}
app.kubernetes.io/name: data
app.kubernetes.io/component: {{ .component }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}
