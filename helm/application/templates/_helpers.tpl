{{/*
Template helpers.

Kubernetes name rules bite hard here: a name must be <= 63 characters and a
label VALUE must also be <= 63 characters. `trunc 63 | trimSuffix "-"` appears
everywhere below because truncating can leave a trailing hyphen, which is not a
legal name character.
*/}}

{{- define "orders-api.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Fully qualified name. If the release is already named after the chart, do not
produce "orders-api-orders-api".
*/}}
{{- define "orders-api.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "orders-api.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Selector labels.

CRITICAL: these must be STABLE for the life of the Deployment. A Deployment's
spec.selector is immutable - if a chart upgrade changes these, `helm upgrade`
fails with "field is immutable" and the only fix is to delete and recreate the
Deployment, which is an outage. That is why version and chart labels live in
`orders-api.labels` and NOT here.
*/}}
{{- define "orders-api.selectorLabels" -}}
app.kubernetes.io/name: {{ include "orders-api.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/*
Full label set. Includes the volatile labels (version, chart) that must never
appear in a selector.

app.kubernetes.io/version is what makes `kubectl get pods -L
app.kubernetes.io/version` a one-line answer to "what version is running" -
the fastest version check there is, short of hitting /version.
*/}}
{{- define "orders-api.labels" -}}
helm.sh/chart: {{ include "orders-api.chart" . }}
{{ include "orders-api.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/component: api
app.kubernetes.io/part-of: orders
{{- with .Values.commonLabels }}
{{ toYaml . }}
{{- end }}
{{- end -}}

{{- define "orders-api.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "orders-api.fullname" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.serviceAccount.name -}}
{{- end -}}
{{- end -}}

{{/*
Resolve the image reference.

If a digest is set it WINS over the tag, and the reference becomes
repository@sha256:... - byte-for-byte deterministic. This is the mechanism that
makes "the pipeline succeeded but the old version is running" impossible.
*/}}
{{- define "orders-api.image" -}}
{{- if .Values.image.digest -}}
{{- printf "%s@%s" .Values.image.repository .Values.image.digest -}}
{{- else -}}
{{- printf "%s:%s" .Values.image.repository (.Values.image.tag | default .Chart.AppVersion) -}}
{{- end -}}
{{- end -}}

{{/*
Guardrail: refuse to render if someone sets image.tag to "latest".

Failing at template time is enormously cheaper than discovering at 02:00 that
your rollback target does not exist. Override deliberately with
--set allowLatestTag=true if you truly need it locally.
*/}}
{{- define "orders-api.validateImage" -}}
{{- if and (eq (.Values.image.tag | toString) "latest") (not .Values.allowLatestTag) -}}
{{- fail "image.tag is 'latest'. Mutable tags make rollback impossible and deploys non-deterministic. Use an immutable version tag or image.digest. Override with --set allowLatestTag=true if you accept that." -}}
{{- end -}}
{{- end -}}
