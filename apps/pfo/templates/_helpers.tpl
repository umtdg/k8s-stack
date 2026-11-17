{{- define "pfo.selector" -}}
app: {{ .Release.Name }}
{{- end -}}

{{- define "pfo.config" -}}
SPRING_DATASOURCE_URL: {{ required "database.url is required" .Values.database.url | quote }}
{{- range $key, $value := .Values.config }}
{{ $key }}: {{ $value | toString | quote }}
{{- end }}
{{- end -}}
