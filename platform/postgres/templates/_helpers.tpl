{{- define "postgres.protect" -}}
annotations:
  argocd.argoproj.io/sync-options: Prune=false,Delete=false
{{- end -}}
