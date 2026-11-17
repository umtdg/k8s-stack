# k8s-stack

Everything that runs on the cluster, one directory per service.

```
Chart.yaml  values.yaml  templates/   the chart Argo CD's `root` Application renders
platform/<service>/                   what the cluster needs to run anything
apps/<service>/                       what the cluster is for
tests/                                tests of the root chart
```

## The root chart

The repository root is a Helm chart. It turns [`values.yaml`](values.yaml)
into:

- the `homelab` AppProject,
- one Application per service that has `argo.managed: true`,
- the `homelab-config` ConfigMap: every shared value in resolved form,
- the `root` Application itself.

It also validates `values.yaml` and each service's directory, in two layers.
[`values.schema.json`](values.schema.json) says what each value must look like
on its own; Helm applies it before any template runs.
[`templates/_validate.tpl`](templates/_validate.tpl) checks how values relate
to each other. A render that fails either one produces nothing.

## A service directory

| File | What |
|---|---|
| `Chart.yaml` | The service's chart. An upstream chart is a dependency, pinned to one exact version. |
| `templates/` | Objects of our own that belong to the service: MetalLB's address pool, the ACME issuers, the wildcard certificate. |
| `values.tpl.yaml` | The values of that chart. The only values file the service has. |
| `apply.sh`, `test.sh`, … | Scripts, tests and fixtures. |

`values.tpl.yaml` is a template. It sees `values.yaml` as `.Values` and its
own catalog entry, with defaults resolved, as `.service`. Anything shared is
written as an expression, never as a literal:

```yaml
ingress:
  className: {{ .Values.ingress.className }}
  hosts:
    - host: {{ include "homelab.host" (list . .service.name) }}
```

Values for an upstream chart sit under that chart's name (`metallb:`,
`argo-cd:`), next to the values of the service's own templates. The result
becomes `spec.source.helm.valuesObject` of the Application.

It is not named `values.yaml` on purpose: Helm would load a file of that name
into the chart as it is, unrendered.

`platform/local-path` has no `Chart.yaml`. Its upstream chart is not
published to a Helm repository, so the catalog points at the upstream git
repository instead (`git:`).

## Where a value lives

| What | Where |
|---|---|
| A value more than one thing depends on: domain, VIP, pool, storage class, Postgres location, hostnames, secret names | `values.yaml`, once |
| Which directory, namespace and sync wave a service has | `values.yaml` → `services` |
| Which upstream chart, at which version | `<service>/Chart.yaml` |
| The Helm values of one service | `<service>/values.tpl.yaml` |
| How a value is derived from others (FQDN, Postgres host) | `templates/_helpers.tpl` |
| What one value must look like: required, type, format | `values.schema.json` |
| How values must relate: the VIP inside the pool, no hostname twice, every chart pinned | `templates/_validate.tpl` |

## Commands

```bash
make validate      # values.yaml is consistent, every Application renders
make test          # the checks reject what they should; templates follow the conventions
make deps          # download the upstream charts named in each Chart.yaml
make test-charts   # every chart here renders with the values it is given
make render        # every Application, managed or not
make config        # every shared value, resolved, as KEY=value
```

`validate`, `test`, `render` and `config` need no network. `make deps` writes
`Chart.lock` next to each `Chart.yaml` the first time; commit those files. The
downloaded charts themselves are ignored by git.

The values one service gets:

```bash
helm template homelab . --set render.all=true -s templates/applications.yaml \
    | yq 'select(.metadata.name == "gitea") | .spec.source.helm.valuesObject'
```

## Adding a service

1. Create `platform/<name>/` or `apps/<name>/` with a `Chart.yaml`. For an
   upstream chart, list it under `dependencies` with an exact version.
2. Add `values.tpl.yaml` if it takes values.
3. Add an entry under `services` in `values.yaml`: `dir`, `wave`,
   `namespace`.
4. `make test`, then `make deps test-charts`.
5. Set `argo.managed: true` when Argo CD should own it. It syncs on its own
   from then on; with `argo.automated: false`, `root` waits at its wave until
   it has been synced by hand.

A service that needs a database also gets an entry under `postgres.databases`
with `consumer.service` set to its name; its values file reads the result
with `include "homelab.databaseFor" (list . .service.name)`.

## Upgrading an upstream chart

Change the version in the service's `Chart.yaml`, run
`helm dependency update <dir>`, and commit `Chart.yaml` and `Chart.lock`
together.

## Rules the templates rely on

- **Applications carry no finalizer.** Deleting an Application, or setting
  `argo.managed: false`, leaves everything it deployed in place.
- **Services that ship CRDs have `argo.prune: false`.** Pruning a CRD deletes
  every object of that kind, and for CloudNativePG that is the database.
- **Objects that need their operator running carry
  `argocd.argoproj.io/sync-wave: "1"`** (the address pool, the issuers).
  Anything that applies a chart outside Argo CD has to apply in that order
  too.
- **A sync wave starts once every Application before it is healthy.** Argo CD
  only knows the health of an Application through the
  `argoproj.io_Application` health check in
  `platform/argocd/values.tpl.yaml`, so the Argo CD that syncs `root` has to
  be installed with those values.
- **Namespaces are created by Argo CD**, never by a chart.
- **Secrets are never rendered.** Charts refer to them by the names under
  `secrets` and `postgres.databases` in `values.yaml`.
- **Services first installed with Helm set `argo.migrateFrom: helm`**, so
  Argo CD takes over field ownership instead of sharing it.

## Conventions

### Names

- **service**: one directory, one chart, one Application. The catalog in
  `values.yaml` is `services`.
- **database**: one entry of `postgres.databases`. The name is the role, the
  database and its owner; `consumer.service` is the service that connects.
- **homelab**: the name of everything the root chart owns. The chart, the
  AppProject, the `homelab-config` ConfigMap, the `homelab.*` helpers and
  the `HOMELAB_*` keys.
- Helpers are named `<chart>.<what they return>`, in full words:
  `homelab.namespace`, `homelab.postgres.host`, `pfo.selector`.
- Keys of `homelab-config` are grouped: `HOMELAB_<VALUE>`,
  `HOMELAB_SERVICE_<NAME>_<FIELD>`, `HOMELAB_DATABASE_<NAME>_<FIELD>`,
  `HOMELAB_SECRET_<NAME>_<FIELD>`.

### Templates (`templates/*.yaml`)

- Two spaces. List items are indented under their key.
- An action that produces no output (control flow, an assignment, a
  comment) sits on its own line and starts with `{{-`. It does not end with
  `-}}`.
- A block inserted with `nindent` sits on its own line, indented like the
  block it inserts, and the number is that indentation: the parent key's
  plus two. The number therefore differs with depth; the pattern does not:

  ```yaml
  metadata:
    labels:
      {{- include "pfo.selector" . | nindent 4 }}
  ```

- The parent key is always written in the template. A helper returns the
  content of a block, never the key above it.
- `toYaml <value> | nindent N`, value first. A required value is wrapped:
  `toYaml (required "x is required" .Values.x) | nindent N`.
- Every value a template cannot work without goes through `required`, with
  the message `<key path> is required`.
- Explanations are template comments, `{{- /* … */}}`, at the top of the
  file or above the line they explain. Rendered manifests carry no
  comments.
- A file does not rebind `.` for its whole length; it assigns a variable
  (`{{- $cluster := .Values.cluster }}`).
- No blank lines inside an object.
- In a `range` that emits objects, each starts with `---`.

### Helpers (`templates/_*.tpl`)

- `define` and its `end` trim on both sides (`{{- define "…" -}}`,
  `{{- end -}}`), so a helper returns exactly its content, with no blank
  line around it.
- The root chart's helper files are logic, not YAML. Every action there is
  on its own line and trims on both sides, so whitespace never reaches the
  output and the code is laid out like code: nested two spaces per level,
  with blank lines between steps.

  ```
  {{- range $name, $service := .Values.services -}}
    {{- if hasKey $dirs $service.dir -}}
      {{- printf "services.%s.dir is already used\n" $name -}}
    {{- end -}}
  {{- end -}}
  ```

- A helper in a service chart that returns a block of YAML (`pfo.config`)
  is content: it follows the template rules above.
- Each `define` has a comment above it: name, arguments, what it returns.
- A check belongs in `values.schema.json` when it concerns one value, and
  in `templates/_validate.tpl` when it concerns how values relate. Each
  `homelab.validate.<area>` helper prints one line per problem.

### Values files (`values.tpl.yaml`)

- Assignments first, one per line.
- Then the values of the service's own templates, under a comment naming
  the template file; then `# Upstream chart.` and the upstream values under
  that chart's name.
- Comments are YAML comments, full sentences, above the key they explain.
- A value that exists in `values.yaml` is an expression, never a literal.

## During the migration

Each service directory still holds the script and manifests it was installed
with (`apply.sh`, `spec.yaml`, `legacy-values.yaml`, …). They are what is
live until the service is switched to its chart, and are removed then.
`platform/cnpg/apply.sh` still installs the operator as well as the cluster.
[`MIGRATION.md`](MIGRATION.md) is the order of the switch.
