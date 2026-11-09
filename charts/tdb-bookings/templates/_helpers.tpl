{{/*
Chart name, truncated to the 63-character DNS label limit.
*/}}
{{- define "tdb-bookings.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Fully qualified app name: <release>-<chart>, or just <release> when it already contains the chart name.
*/}}
{{- define "tdb-bookings.fullname" -}}
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
Chart label value: <name>-<version>.
*/}}
{{- define "tdb-bookings.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Selector labels. Immutable on a Deployment, so they never include versions.
*/}}
{{- define "tdb-bookings.selectorLabels" -}}
app.kubernetes.io/name: {{ include "tdb-bookings.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Common labels for every object.
*/}}
{{- define "tdb-bookings.labels" -}}
helm.sh/chart: {{ include "tdb-bookings.chart" . }}
{{ include "tdb-bookings.selectorLabels" . }}
app.kubernetes.io/version: {{ include "tdb-bookings.imageVersion" . | quote }}
app.kubernetes.io/component: api
app.kubernetes.io/part-of: tdb-bookings
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Version label: the image tag when set, else the chart appVersion. Label values allow at most 63 characters
(a sha-<40 hex> tag is 44).
*/}}
{{- define "tdb-bookings.imageVersion" -}}
{{- default .Chart.AppVersion .Values.image.tag | trunc 63 | trimSuffix "-" | trimSuffix "." }}
{{- end }}

{{/*
Image reference. A digest wins over a tag (immutable: what was tested is what runs).
The schema already rejects both empty; this guard covers --disable-openapi-validation style bypasses.
*/}}
{{- define "tdb-bookings.image" -}}
{{- $img := .Values.image }}
{{- if $img.digest }}
{{- printf "%s@%s" $img.repository $img.digest }}
{{- else if $img.tag }}
{{- printf "%s:%s" $img.repository $img.tag }}
{{- else }}
{{- fail "image.digest or image.tag is required (e.g. --set image.tag=sha-<commit sha>)" }}
{{- end }}
{{- end }}

{{/*
ServiceAccount name.
*/}}
{{- define "tdb-bookings.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "tdb-bookings.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Lowest replica count the release can run at: the HPA floor when autoscaling, else replicaCount.
*/}}
{{- define "tdb-bookings.minReplicas" -}}
{{- if .Values.autoscaling.enabled }}
{{- .Values.autoscaling.minReplicas }}
{{- else }}
{{- .Values.replicaCount }}
{{- end }}
{{- end }}

{{/*
Cross-field checks JSON Schema draft-07 cannot express. Rendered from the Deployment so they always run.
*/}}
{{- define "tdb-bookings.validate" -}}
{{- if le (int .Values.terminationGracePeriodSeconds) (int .Values.preStopSleepSeconds) }}
{{- fail "terminationGracePeriodSeconds must be greater than preStopSleepSeconds, or SIGKILL lands before uvicorn can drain" }}
{{- end }}
{{- if and .Values.autoscaling.enabled (gt (int .Values.autoscaling.minReplicas) (int .Values.autoscaling.maxReplicas)) }}
{{- fail "autoscaling.minReplicas must be <= autoscaling.maxReplicas" }}
{{- end }}
{{- if and .Values.autoscaling.enabled (lt (int .Values.autoscaling.targetCPUUtilizationPercentage) 1) }}
{{- fail "autoscaling.targetCPUUtilizationPercentage must be set when autoscaling is enabled" }}
{{- end }}
{{- $pdb := .Values.podDisruptionBudget }}
{{- if and $pdb.enabled (not (kindIs "string" $pdb.minAvailable)) }}
{{- if ge (int $pdb.minAvailable) (int (include "tdb-bookings.minReplicas" .)) }}
{{- fail (printf "podDisruptionBudget.minAvailable (%d) must be lower than the minimum replica count (%s), otherwise no pod can ever be evicted and node drains hang" (int $pdb.minAvailable) (include "tdb-bookings.minReplicas" .)) }}
{{- end }}
{{- end }}
{{- end }}
