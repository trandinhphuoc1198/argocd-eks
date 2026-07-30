{{/*
Expand the name of the chart.
*/}}
{{- define "otel.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "otel.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "otel.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels — attached to all resources.

By default app.kubernetes.io/name is the chart name (call as `include "otel.labels" .`).

IMPORTANT: for the two OpenTelemetryCollector CRs (daemonset.yaml / deployment.yaml),
DO NOT use the default. The OTel Operator copies whatever labels already exist on the
CR onto every child resource it generates (Service, headless Service, monitoring
Service, the underlying DaemonSet/Deployment) and only fills in app.kubernetes.io/name
itself if the CR doesn't already have one set. If we let the chart default ("otel")
win here, every generated Service ends up labeled app.kubernetes.io/name=otel instead
of <name>-collector — which is exactly what broke ServiceMonitor scraping.
So for those two CRs, pass an explicit override that matches what the Operator would
have generated on its own:
  {{ include "otel.labels" (dict "root" . "name" (include "otel.collectorDS.serviceName" .)) }}
*/}}
{{- define "otel.labels" -}}
{{- $root := . -}}
{{- if and (kindIs "map" .) (hasKey . "root") -}}
{{- $root = .root -}}
{{- end -}}
helm.sh/chart: {{ include "otel.chart" $root }}
{{ include "otel.selectorLabels" . }}
{{- if $root.Chart.AppVersion }}
app.kubernetes.io/version: {{ $root.Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ $root.Release.Service }}
{{- end }}

{{/*
Selector labels — used in spec.selector.matchLabels.
Same calling convention as otel.labels: plain `.` for the chart-name default,
or `(dict "root" . "name" "...")` to override app.kubernetes.io/name.
*/}}
{{- define "otel.selectorLabels" -}}
{{- $root := . -}}
{{- $name := "" -}}
{{- if and (kindIs "map" .) (hasKey . "root") -}}
{{- $root = .root -}}
{{- $name = .name -}}
{{- else -}}
{{- $name = include "otel.name" . -}}
{{- end -}}
app.kubernetes.io/name: {{ $name }}
app.kubernetes.io/instance: {{ $root.Release.Name }}
{{- end }}

{{/*
DaemonSet Collector name (the OpenTelemetryCollector CR's metadata.name)
*/}}
{{- define "otel.collectorDS.name" -}}
{{- .Values.collectorDaemonSet.name }}
{{- end }}

{{/*
Aggregator (Deployment) Collector name (the OpenTelemetryCollector CR's metadata.name)
*/}}
{{- define "otel.collectorAgg.name" -}}
{{- .Values.collectorDeployment.name }}
{{- end }}

{{/*
DaemonSet Collector — name of the main ClusterIP Service the Operator generates
(naming.Service / naming.Collector in the Operator both resolve to "<crname>-collector").
This is the SINGLE SOURCE OF TRUTH used both for the CR's own app.kubernetes.io/name
label override above and for the ServiceMonitor selector — keep them unified here.
*/}}
{{- define "otel.collectorDS.serviceName" -}}
{{- include "otel.collectorDS.name" . }}-collector
{{- end }}

{{/*
Aggregator Collector — name of the main ClusterIP Service the Operator generates.
*/}}
{{- define "otel.collectorAgg.serviceName" -}}
{{- include "otel.collectorAgg.name" . }}-collector
{{- end }}
