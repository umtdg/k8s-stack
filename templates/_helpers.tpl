{{- define "homelab.service" -}}
  {{- $ctx := index . 0 -}}
  {{- $name := index . 1 -}}
  {{- $entry := index $ctx.Values.services $name -}}
  {{- if not $entry -}}
    {{- fail (printf "values.yaml: service %q is referenced but not defined under services" $name) -}}
  {{- end -}}

  {{- $service := deepCopy $entry -}}
  {{- $_ := set $service "name" $name -}}
  {{- if not $service.releaseName -}}
    {{- $_ := set $service "releaseName" $name -}}
  {{- end -}}
  {{- if not (hasKey $service "createNamespace") -}}
    {{- $_ := set $service "createNamespace" true -}}
  {{- end -}}

  {{- /* mergeOverwrite does not let `false` win over `true`. */ -}}
  {{- $argo := deepCopy $ctx.Values.argoDefaults -}}
  {{- range $key, $value := $entry.argo -}}
    {{- $_ := set $argo $key $value -}}
  {{- end -}}
  {{- $_ := set $service "argo" $argo -}}

  {{- toYaml $service -}}
{{- end -}}

{{- define "homelab.namespace" -}}
  {{- (include "homelab.service" . | fromYaml).namespace -}}
{{- end -}}

{{- define "homelab.argocd.namespace" -}}
  {{- include "homelab.namespace" (list . "argocd") -}}
{{- end -}}

{{- define "homelab.chart" -}}
  {{- $ctx := index . 0 -}}
  {{- $entry := index $ctx.Values.services (index . 1) -}}
  {{- $ctx.Files.Get (printf "%s/Chart.yaml" $entry.dir) -}}
{{- end -}}

{{- define "homelab.serviceValues" -}}
  {{- $ctx := index . 0 -}}
  {{- $service := include "homelab.service" . | fromYaml -}}
  {{- $file := printf "%s/values.tpl.yaml" $service.dir -}}
  {{- $source := $ctx.Files.Get $file -}}
  {{- if $source -}}
    {{- $scope := dict "Values" $ctx.Values "Files" $ctx.Files "Template" $ctx.Template "Chart" $ctx.Chart "Release" $ctx.Release "service" $service -}}
    {{- $values := tpl $source $scope | fromYaml -}}
    {{- if hasKey $values "Error" -}}
      {{- fail (printf "%s does not render to valid YAML: %s" $file $values.Error) -}}
    {{- end -}}
    {{- if $values -}}
      {{- toYaml $values -}}
    {{- end -}}
  {{- end -}}
{{- end -}}


{{- define "homelab.fqdn" -}}
  {{- $ctx := index . 0 -}}
  {{- printf "%s.%s" (index . 1) $ctx.Values.domain -}}
{{- end -}}

{{- define "homelab.host" -}}
  {{- $ctx := index . 0 -}}
  {{- $service := include "homelab.service" . | fromYaml -}}
  {{- if not $service.host -}}
    {{- fail (printf "values.yaml: service %q has no host" $service.name) -}}
  {{- end -}}
  {{- include "homelab.fqdn" (list $ctx $service.host) -}}
{{- end -}}

{{- define "homelab.ingress.annotations" -}}
nginx.ingress.kubernetes.io/ssl-redirect: "true"
{{- end -}}


{{- define "homelab.postgres.host" -}}
  {{- printf "%s-rw.%s.svc.cluster.local" .Values.postgres.cluster (include "homelab.namespace" (list . "postgres")) -}}
{{- end -}}

{{- define "homelab.postgres.address" -}}
  {{- printf "%s:%v" (include "homelab.postgres.host" .) .Values.postgres.port -}}
{{- end -}}

{{- define "homelab.databaseFor" -}}
  {{- $ctx := index . 0 -}}
  {{- $name := index . 1 -}}
  {{- $database := dict -}}
  {{- range $ctx.Values.postgres.databases -}}
    {{- if eq .consumer.service $name -}}
      {{- $database = deepCopy . -}}
    {{- end -}}
  {{- end -}}
  {{- if not $database -}}
    {{- fail (printf "values.yaml: no entry of postgres.databases has consumer.service %q" $name) -}}
  {{- end -}}
  {{- $_ := set $database.consumer "namespace" (include "homelab.namespace" (list $ctx $name)) -}}
  {{- toYaml $database -}}
{{- end -}}


{{- define "homelab.ipToInt" -}}
  {{- $octets := splitList "." . -}}
  {{- $a := index $octets 0 | atoi -}}
  {{- $b := index $octets 1 | atoi -}}
  {{- $c := index $octets 2 | atoi -}}
  {{- $d := index $octets 3 | atoi -}}
  {{- add (mul $a 16777216) (mul $b 65536) (mul $c 256) $d -}}
{{- end -}}
