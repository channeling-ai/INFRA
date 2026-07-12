{{/*
공통 라벨 — 모든 리소스에 박힘
*/}}
{{- define "chaneling.labels" -}}
app.kubernetes.io/name: chaneling
app.kubernetes.io/managed-by: argocd
app.kubernetes.io/instance: {{ .Release.Name }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end }}

{{/*
워크로드별 selector 라벨 — Deployment/Service matchLabels에 사용
component는 호출 시 인자로 전달: include "chaneling.selectorLabels" (dict "Release" .Release "component" "spring")
*/}}
{{- define "chaneling.selectorLabels" -}}
app.kubernetes.io/name: chaneling
app.kubernetes.io/component: {{ .component }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
공통 env block — ConfigMap + Secret 참조
{{ include "chaneling.commonEnv" . }} 로 호출
*/}}
{{- define "chaneling.commonEnv" -}}
- name: TZ
  value: {{ .Values.config.tz | quote }}
- name: ENV
  value: {{ .Values.config.env | quote }}
- name: PG_HOST
  value: {{ .Values.config.pgHost | quote }}
- name: PG_PORT
  value: {{ .Values.config.pgPort | quote }}
- name: PG_DATABASE
  value: {{ .Values.config.pgDatabase | quote }}
- name: PG_USER
  value: {{ .Values.config.pgUser | quote }}
- name: PG_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ .Values.secrets.existingSecret }}
      key: PG_PASSWORD
- name: REDIS_HOST
  value: {{ .Values.config.redisHost | quote }}
- name: KAFKA_BOOTSTRAP_SERVERS
  value: {{ .Values.config.kafkaBootstrap | quote }}
- name: JWT_SECRET
  valueFrom:
    secretKeyRef:
      name: {{ .Values.secrets.existingSecret }}
      key: JWT_SECRET
{{- end }}

{{/*
LLM/Consumer용 추가 env (OpenAI, SerpAPI 등)
*/}}
{{- define "chaneling.llmEnv" -}}
- name: OPENAI_API_KEY
  valueFrom:
    secretKeyRef:
      name: {{ .Values.secrets.existingSecret }}
      key: OPENAI_API_KEY
- name: SERPAPI_KEY
  valueFrom:
    secretKeyRef:
      name: {{ .Values.secrets.existingSecret }}
      key: SERPAPI_KEY
- name: YOUTUBE_API_KEY
  valueFrom:
    secretKeyRef:
      name: {{ .Values.secrets.existingSecret }}
      key: YOUTUBE_API_KEY
- name: PROXY_USERNAME
  valueFrom:
    secretKeyRef:
      name: {{ .Values.secrets.existingSecret }}
      key: PROXY_USERNAME
- name: PROXY_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ .Values.secrets.existingSecret }}
      key: PROXY_PASSWORD
- name: DISCORD_WEBHOOK_URL
  valueFrom:
    secretKeyRef:
      name: {{ .Values.secrets.existingSecret }}
      key: DISCORD_WEBHOOK_URL
{{- end }}

{{/*
Spring용 추가 env (S3, Google OAuth)
*/}}
{{- define "chaneling.springExtraEnv" -}}
- name: SPRING_PROFILES_ACTIVE
  value: {{ .Values.config.springProfilesActive | quote }}
- name: FASTAPI_URL
  value: {{ .Values.config.fastapiUrl | quote }}
- name: FRONT_URL
  value: {{ .Values.config.frontUrl | quote }}
# spring도 YouTube API 사용 (시크릿엔 이미 YOUTUBE_API_KEY 존재)
- name: YOUTUBE_API_KEY
  valueFrom:
    secretKeyRef:
      name: {{ .Values.secrets.existingSecret }}
      key: YOUTUBE_API_KEY
- name: AWS_REGION
  value: {{ .Values.config.awsRegion | quote }}
# S3 endpoint override (OCI, 빈 문자열이면 AWS SDK default로 fallback)
- name: AWS_ENDPOINT_URL_S3
  valueFrom:
    secretKeyRef:
      name: {{ .Values.secrets.existingSecret }}
      key: AWS_ENDPOINT_URL_S3
# public 버킷 접근용 베이스 URL (AWS/OCI 공통 추상화)
- name: S3_PUBLIC_URL_BASE
  valueFrom:
    secretKeyRef:
      name: {{ .Values.secrets.existingSecret }}
      key: S3_PUBLIC_URL_BASE
- name: AWS_S3_PRIVATE_BUCKET
  valueFrom:
    secretKeyRef:
      name: {{ .Values.secrets.existingSecret }}
      key: AWS_S3_PRIVATE_BUCKET
- name: AWS_S3_PUBLIC_BUCKET
  valueFrom:
    secretKeyRef:
      name: {{ .Values.secrets.existingSecret }}
      key: AWS_S3_PUBLIC_BUCKET
- name: AWS_ACCESS_KEY_ID
  valueFrom:
    secretKeyRef:
      name: {{ .Values.secrets.existingSecret }}
      key: AWS_ACCESS_KEY_ID
- name: AWS_SECRET_ACCESS_KEY
  valueFrom:
    secretKeyRef:
      name: {{ .Values.secrets.existingSecret }}
      key: AWS_SECRET_ACCESS_KEY
- name: GOOGLE_CLIENT_ID
  valueFrom:
    secretKeyRef:
      name: {{ .Values.secrets.existingSecret }}
      key: GOOGLE_CLIENT_ID
- name: GOOGLE_CLIENT_SECRET
  valueFrom:
    secretKeyRef:
      name: {{ .Values.secrets.existingSecret }}
      key: GOOGLE_CLIENT_SECRET
- name: GOOGLE_REDIRECT_URI
  valueFrom:
    secretKeyRef:
      name: {{ .Values.secrets.existingSecret }}
      key: GOOGLE_REDIRECT_URI
{{- end }}

{{/*
같은 component끼리는 다른 노드에 배치 (preferred). 노드 1대뿐일 땐 무시.
*/}}
{{- define "chaneling.antiAffinity" -}}
podAntiAffinity:
  preferredDuringSchedulingIgnoredDuringExecution:
    - weight: 100
      podAffinityTerm:
        labelSelector:
          matchLabels:
            app.kubernetes.io/name: chaneling
            app.kubernetes.io/component: {{ .component }}
        topologyKey: kubernetes.io/hostname
{{- end }}
