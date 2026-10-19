{{/*
Naming convention. Everything is derived from app.name and app.env:

  namespace     <name>-<env>
  Deployment    <name>
  Service       <name>
  Certificate   <name>-<env>-tls   (in the ingress namespace, next to the gateway pods)
  Gateway       <name>-<env>       (in the ingress namespace, bound to the shared ingress)
  HTTPRoute     <name>, <name>-redirect
  subdomain     <name>-<env>.<domain>, or <name>.<domain> when env = prod
*/}}

{{- define "app.validate" -}}
{{- $a := .Values.app -}}
{{- if not (regexMatch "^[a-z][a-z0-9-]{0,28}[a-z0-9]$" ($a.name | toString)) -}}
{{- fail (printf "app.name %q is invalid: use 2-30 lowercase letters, digits or '-', starting with a letter" ($a.name | toString)) -}}
{{- end -}}
{{- if not (has ($a.env | toString) (list "dev" "staging" "prod")) -}}
{{- fail (printf "app.env %q is invalid: use dev, staging or prod" ($a.env | toString)) -}}
{{- end -}}
{{- end -}}

{{- define "app.name" -}}{{ .Values.app.name }}{{- end -}}
{{- define "app.id" -}}{{ .Values.app.name }}-{{ .Values.app.env }}{{- end -}}
{{- define "app.namespace" -}}{{ include "app.id" . }}{{- end -}}
{{- define "app.tlsSecret" -}}{{ include "app.id" . }}-tls{{- end -}}
{{- define "app.gateway" -}}{{ include "app.id" . }}{{- end -}}

{{- define "app.host" -}}
{{- if eq .Values.app.env "prod" -}}
{{ .Values.app.name }}.{{ .Values.platform.domain }}
{{- else -}}
{{ .Values.app.name }}-{{ .Values.app.env }}.{{ .Values.platform.domain }}
{{- end -}}
{{- end -}}

{{- define "app.labels" -}}
app.kubernetes.io/name: {{ .Values.app.name }}
app.kubernetes.io/instance: {{ include "app.id" . }}
app.kubernetes.io/managed-by: platform-app-template
environment: {{ .Values.app.env }}
{{- end -}}

{{- define "app.selector" -}}
app.kubernetes.io/name: {{ .Values.app.name }}
app.kubernetes.io/instance: {{ include "app.id" . }}
{{- end -}}
