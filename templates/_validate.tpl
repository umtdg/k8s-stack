{{- define "homelab.validate" -}}
  {{- $problems := list -}}
  {{- range $area := list "network" "services" "charts" "databases" "secrets" -}}
    {{- range splitList "\n" (include (printf "homelab.validate.%s" $area) $) -}}
      {{- if . -}}
        {{- $problems = append $problems . -}}
      {{- end -}}
    {{- end -}}
  {{- end -}}

  {{- if $problems -}}
    {{- fail (printf "\n\nvalues.yaml is invalid (%d problem(s)):\n  - %s\n" (len $problems) (join "\n  - " $problems)) -}}
  {{- end -}}
{{- end -}}


{{- define "homelab.validate.network" -}}
  {{- $network := .Values.network -}}
  {{- $pool := $network.pool -}}
  {{- $range := printf "%s-%s" $pool.start $pool.end -}}

  {{- $start := include "homelab.ipToInt" $pool.start | int64 -}}
  {{- $end := include "homelab.ipToInt" $pool.end | int64 -}}
  {{- $vip := include "homelab.ipToInt" $network.ingressVIP | int64 -}}
  {{- $node := include "homelab.ipToInt" $network.nodeIP | int64 -}}

  {{- if gt $start $end -}}
    {{- printf "network.pool.start (%s) is after network.pool.end (%s)\n" $pool.start $pool.end -}}
  {{- else -}}
    {{- if or (lt $vip $start) (gt $vip $end) -}}
      {{- printf "network.ingressVIP (%s) is outside the MetalLB pool %s; MetalLB would never assign it\n" $network.ingressVIP $range -}}
    {{- end -}}
    {{- if and (ge $node $start) (le $node $end) -}}
      {{- printf "network.nodeIP (%s) is inside the MetalLB pool %s; a Service could take over the node's address\n" $network.nodeIP $range -}}
    {{- end -}}
  {{- end -}}
{{- end -}}


{{- define "homelab.validate.services" -}}
  {{- $dirs := dict -}}
  {{- $hosts := dict -}}
  {{- range $name, $service := .Values.services -}}
    {{- if hasKey $dirs $service.dir -}}
      {{- printf "services.%s.dir %q is already used by services.%s\n" $name $service.dir (get $dirs $service.dir) -}}
    {{- end -}}
    {{- $_ := set $dirs $service.dir $name -}}

    {{- with $service.host -}}
      {{- if hasKey $hosts . -}}
        {{- printf "services.%s.host %q is already used by services.%s\n" $name . (get $hosts .) -}}
      {{- end -}}
      {{- $_ := set $hosts . $name -}}
    {{- end -}}
  {{- end -}}
{{- end -}}


{{- define "homelab.validate.charts" -}}
  {{- $floating := list "latest" "*" "main" "master" "head" -}}
  {{- $exactVersion := "^v?[0-9]+\\.[0-9]+\\.[0-9]+(-[0-9A-Za-z.-]+)?$" -}}

  {{- range $name, $service := .Values.services -}}
    {{- $chartFile := printf "%s/Chart.yaml" $service.dir -}}
    {{- $chart := $.Files.Get $chartFile | fromYaml -}}

    {{- if and $service.git $chart -}}
      {{- printf "services.%s has git set, but %s exists; a service has one chart\n" $name $chartFile -}}
    {{- else if $service.git -}}
      {{- if has (lower $service.git.ref) $floating -}}
        {{- printf "services.%s.git.ref %q is not a pinned tag or commit\n" $name $service.git.ref -}}
      {{- end -}}
    {{- else if not $chart -}}
      {{- printf "services.%s: %s not found; add the chart or set git\n" $name $chartFile -}}
    {{- else if hasKey $chart "Error" -}}
      {{- printf "%s is not valid YAML: %s\n" $chartFile $chart.Error -}}
    {{- end -}}

    {{- range $chart.dependencies -}}
      {{- if not (regexMatch $exactVersion (toString .version)) -}}
        {{- printf "%s: dependency %q has version %q; pin one exact version\n" $chartFile .name (toString .version) -}}
      {{- end -}}
      {{- if not (hasPrefix "https://" (toString .repository)) -}}
        {{- printf "%s: dependency %q needs an https:// repository\n" $chartFile .name -}}
      {{- end -}}
    {{- end -}}
  {{- end -}}
{{- end -}}


{{- define "homelab.validate.databases" -}}
  {{- $names := dict -}}
  {{- $secrets := dict -}}
  {{- $consumers := dict -}}
  {{- range $index, $database := .Values.postgres.databases -}}
    {{- $at := printf "postgres.databases[%d]" $index -}}
    {{- $consumer := $database.consumer.service -}}

    {{- if hasKey $names $database.name -}}
      {{- printf "%s.name %q is used twice\n" $at $database.name -}}
    {{- end -}}
    {{- if hasKey $secrets $database.secret -}}
      {{- printf "%s.secret %q is used twice\n" $at $database.secret -}}
    {{- end -}}
    {{- if hasKey $consumers $consumer -}}
      {{- printf "%s: service %q already consumes another database\n" $at $consumer -}}
    {{- end -}}
    {{- if not (hasKey $.Values.services $consumer) -}}
      {{- printf "%s.consumer.service %q is not a service\n" $at $consumer -}}
    {{- end -}}

    {{- $_ := set $names $database.name true -}}
    {{- $_ := set $secrets $database.secret true -}}
    {{- $_ := set $consumers $consumer true -}}
  {{- end -}}
{{- end -}}


{{- define "homelab.validate.secrets" -}}
  {{- range $name, $secret := .Values.secrets -}}
    {{- if not (hasKey $.Values.services $secret.service) -}}
      {{- printf "secrets.%s.service %q is not a service\n" $name $secret.service -}}
    {{- end -}}
  {{- end -}}
{{- end -}}
