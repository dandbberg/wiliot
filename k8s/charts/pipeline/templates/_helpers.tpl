{{- define "pipeline.labels" -}}
app.kubernetes.io/part-of: {{ .Chart.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end }}

{{- define "pipeline.image" -}}
{{ .Values.image.repository }}:{{ .Values.image.tag }}
{{- end }}

{{/* Split so each pod only gets what it uses: the producer never sees DB settings or secrets. */}}
{{- define "pipeline.regionEnv" -}}
- name: AWS_REGION
  value: {{ .Values.region | quote }}
{{- end }}

{{- define "pipeline.kafkaEnv" -}}
- name: KAFKA_BOOTSTRAP
  value: {{ required "kafka.bootstrap is required" .Values.kafka.bootstrap | quote }}
- name: KAFKA_AUTH
  value: {{ .Values.kafka.auth | quote }}
- name: KAFKA_TOPIC
  value: {{ .Values.kafka.topic | quote }}
{{- end }}

{{- define "pipeline.dbEnv" -}}
- name: DB_HOST
  value: {{ required "db.host is required" .Values.db.host | quote }}
- name: DB_PORT
  value: {{ .Values.db.port | quote }}
- name: DB_NAME
  value: {{ .Values.db.name | quote }}
- name: DB_AUTH
  value: {{ .Values.db.auth | quote }}
- name: DB_USER
  value: {{ .Values.db.user | quote }}
{{- if eq .Values.db.auth "password" }}
- name: DB_SSLMODE
  value: {{ .Values.db.sslmode | quote }}
- name: DB_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ required "db.passwordSecret is required for auth=password" .Values.db.passwordSecret }}
      key: consumer-password
{{- end }}
{{- end }}

{{- define "pipeline.podSecurity" -}}
securityContext:
  runAsNonRoot: true
  seccompProfile:
    type: RuntimeDefault
{{- end }}

{{- define "pipeline.containerSecurity" -}}
securityContext:
  allowPrivilegeEscalation: false
  readOnlyRootFilesystem: true
  capabilities:
    drop: [ALL]
{{- end }}

{{- define "pipeline.probes" -}}
startupProbe:
  httpGet: {path: /healthz, port: health}
  periodSeconds: 5
  failureThreshold: 24
livenessProbe:
  httpGet: {path: /healthz, port: health}
  periodSeconds: 10
  failureThreshold: 3
readinessProbe:
  httpGet: {path: /readyz, port: health}
  periodSeconds: 10
{{- end }}
