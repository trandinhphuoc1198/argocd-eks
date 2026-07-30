{{/*
Expand the name of the chart.
*/}}
{{- define "postgresql.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Cluster name — always use the explicit cluster.name value.
*/}}
{{- define "postgresql.clusterName" -}}
{{ .Values.cluster.name }}
{{- end }}

{{/*
Pooler name.
*/}}
{{- define "postgresql.poolerName" -}}
{{ .Values.pooler.name }}
{{- end }}

{{/*
Secret name.
*/}}
{{- define "postgresql.secretName" -}}
{{ .Values.secret.name }}
{{- end }}

{{/*
Common labels.
*/}}
{{- define "postgresql.labels" -}}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
app.kubernetes.io/name: {{ include "postgresql.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Monitoring labels — must match kube-prometheus-stack serviceMonitorSelector.
*/}}
{{- define "postgresql.monitoringLabels" -}}
release: {{ .Values.monitoring.prometheusRelease }}
{{- end }}
