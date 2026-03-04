{{/*
Return the fullname for the nominatim subchart release.
This mirrors the naming the subchart uses so our custom resources
target the correct service/pods.
*/}}
{{- define "chart.nominatim.fullname" -}}
{{- if .Values.nominatim.fullnameOverride -}}
  {{- .Values.nominatim.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
  {{- $name := default "nominatim" .Values.nominatim.nameOverride -}}
  {{- if contains $name .Release.Name -}}
    {{- .Release.Name | trunc 63 | trimSuffix "-" -}}
  {{- else -}}
    {{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
  {{- end -}}
{{- end -}}
{{- end -}}

{{/*
Return the namespace to use.
*/}}
{{- define "chart.namespace" -}}
{{- default .Release.Namespace .Values.namespaceOverride -}}
{{- end -}}
