# Simplify the root chart

This guide rebuilds the root chart in the plain "app of apps" form from the
Argo CD docs, [Cluster Bootstrapping](https://argo-cd.readthedocs.io/en/stable/operator-manual/cluster-bootstrapping/#app-of-apps-pattern-alternative).
You write each Application by hand, one service at a time, and check each one
against what the chart renders today.

It only changes files in this repository, not the cluster. Do it before
`MIGRATION.md`.

Validation is left out on purpose. First get a plain app of apps working, then
add checks back ([Later: validation](#later-validation)).

The steps were tried on a copy of the repository, starting from its current
state. The cluster commands were not tried.

## How app of apps works

An Argo CD **Application** says: take this folder from a git repository,
render it, and apply the result to this cluster and namespace. If the folder
is a Helm chart, Argo CD renders it with `helm template`, using the values the
Application gives it.

The app-of-apps pattern has one Application, `root`, whose folder is a chart
that renders more Applications:

```
root            folder: the top of this repository (Chart.yaml, values.yaml, templates/)
├── metallb     folder: platform/metallb
├── local-path  folder: deploy/chart/local-path-provisioner in rancher's repository
├── ...
├── argocd      folder: platform/argocd
└── root        root renders itself too, so its own settings live in git
```

So this repository has two kinds of charts:

- **The root chart** is the top folder. Each file in its `templates/` is one
  Application. Its `values.yaml` holds the values that more than one service
  needs, such as the domain.
- **A service chart** is a folder such as `platform/metallb`. It deploys the
  service. Most service charts only wrap an upstream chart (`dependencies` in
  `Chart.yaml`) and add a few objects of their own in `templates/`.

Each template in the root chart writes the service's values into its
Application, under `spec.source.helm.valuesObject`. This is where shared
values come in. The template says `{{ .Values.domain }}`, and the service
chart gets `umtdg.com`.

When you push a change:

1. Argo CD notices the new commit. It checks git every 3 minutes.
2. It renders the root chart again. If an Application changed, for example
   because you changed the domain, `root` applies the new Application.
3. That Application syncs. Argo CD renders its service chart with the new
   values and applies the result.

**Sync waves** set the order. Each Application has an annotation such as
`argocd.argoproj.io/sync-wave: "-30"`. `root` applies the lowest wave first,
and waits until every Application in it is healthy before it starts the next
one. For example, MetalLB comes before ingress-nginx, because ingress-nginx
needs an address from MetalLB.

Argo CD can only tell that an Application is healthy if it has a health check
for Applications. Argo CD 1.8 removed the built-in one, and the docs show how
to add it back ([Argocd App](https://argo-cd.readthedocs.io/en/stable/operator-manual/health/#argocd-app)).
Ours is in Argo CD's own values, in `templates/argocd.yaml`. Without it,
`root` starts every wave at once.

**No finalizers.** The example in the docs puts
`resources-finalizer.argocd.argoproj.io` on each Application, so that deleting
the Application also deletes everything it deployed. We leave it out on
purpose: deleting the postgres Application would then delete the database.
Without the finalizer, a deleted Application leaves its objects running.

## What changes

| Today | After this guide |
|---|---|
| `templates/applications.yaml` loops over the `services` list in `values.yaml`, using helpers from `_helpers.tpl` | One plain file per Application in `templates/`, like the docs' example |
| Each service's values are in `<service>/values.tpl.yaml` | They are in the service's file in `templates/`, under `valuesObject` |
| `values.yaml` has 159 lines: every setting of every service | 74 lines: only the values more than one template needs |
| `values.schema.json` and the checks in `make test` | Gone for now |
| The `homelab` AppProject | The built-in `default` project, like the docs' example |
| `generated/` and `make generate` | Gone: Argo CD renders the root chart itself |

## Before you start

Your working tree is part way through the earlier version of this guide.
That's fine: this guide starts from there. What you added for that version,
such as `homelab.services`, is replaced by the new templates.

You need helm and mikefarah's yq (the Go one). Check yq:

```bash
yq --version
```

The output must mention `mikefarah`.

Stay on a branch, not `main`. `root` deploys `main`.

Download the upstream charts. The comparisons below render them:

```bash
make deps
```

Delete `values.schema.json`. It has a syntax error right now, so the chart
doesn't render. This guide removes it anyway:

```bash
rm values.schema.json
helm template homelab . > /dev/null && echo "renders"
```

### Save today's output

You compare your work against what the chart renders now. Save this script as
`/tmp/compare.sh`:

```bash
#!/usr/bin/env bash
# Usage:
#   compare.sh before          save what the root chart renders today
#   compare.sh after [name]    render again and compare, one Application or all
set -euo pipefail

out=/tmp/$1
rm -rf "$out"
mkdir -p "$out/charts"

# One file per Application. Keys are sorted, comments and quoting removed,
# so only real differences show.
helm template homelab . \
    | yq 'select(.kind == "Application") | sort_keys(..) | ... comments="" | ... style=""' \
    | (cd "$out" && yq -N -s '.metadata.name + ".yaml"' '.')

# The new templates use the "default" project. Hide that known difference.
if [[ $1 == before ]]; then
    for f in "$out"/*.yaml; do
        [[ $(basename "$f") == root.yaml ]] || yq -i '.spec.project = "default"' "$f"
    done
fi

# What each chart in this repository renders with the values it gets.
for f in "$out"/*.yaml; do
    path=$(yq '.spec.source.path' "$f")
    [[ $path != . && -f $path/Chart.yaml ]] || continue
    yq '.spec.source.helm.valuesObject // {}' "$f" \
        | helm template "$(yq '.metadata.name' "$f")" "$path" \
            -n "$(yq '.spec.destination.namespace' "$f")" -f - \
        > "$out/charts/$(basename "$f")"
done

[[ $1 == after ]] || exit 0
if [[ -n ${2:-} ]]; then
    diff "/tmp/before/$2.yaml" "/tmp/after/$2.yaml"
    if [[ -f /tmp/before/charts/$2.yaml ]]; then
        diff "/tmp/before/charts/$2.yaml" "/tmp/after/charts/$2.yaml"
    fi
else
    diff -r /tmp/before /tmp/after
fi
echo "No differences."
```

It compares two things for each service:

- **The Application** that the root chart renders, in `/tmp/before/<name>.yaml`.
- **What the service chart renders** with that Application's values, in
  `/tmp/before/charts/<name>.yaml`. This is what ends up in the cluster.

Save today's output once:

```bash
bash /tmp/compare.sh before
ls /tmp/before
```

You should see `root.yaml`, one file per service, and the `charts` folder.

The old `values.yaml` goes away in step 2. Keep a copy, so you can look things
up:

```bash
cp values.yaml /tmp/old-values.yaml
```

## Step 1: Remove the generator

Delete the files that built the Applications from the `services` list:

```bash
rm templates/_helpers.tpl templates/applications.yaml templates/project.yaml
rm tests/style_test.sh
rm -r generated
```

What they were:

- **`_helpers.tpl` and `applications.yaml`** built every Application from the
  `services` list. From now on, each Application is written out in its own
  file.
- **`project.yaml`** made the `homelab` AppProject. An AppProject limits which
  repositories and namespaces its Applications may use. With one person
  running the cluster, the built-in `default` project, which allows
  everything, is enough. `MIGRATION.md` deletes the old project from the
  cluster.
- **`tests/style_test.sh`** checked how the helpers were laid out.
- **`generated/`** was for committing the rendered Applications. Argo CD now
  renders the root chart itself, as in the docs.

Keep the `values.tpl.yaml` files for now. You copy them into the new
templates in steps 4 and 5.

## Step 2: Write the shared values

Replace `values.yaml` with this:

```yaml
# Values that more than one template in templates/ needs, or that have to
# agree with each other. A value only one template uses is written in that
# template instead.

# This repository. Every Application except local-path reads its chart from
# here.
repo:
  url: git@github.com:umtdg/k8s-stack.git
  revision: main

# How every Application retries a failed sync.
retry:
  limit: 5
  refresh: true
  backoff:
    duration: 10s
    factor: 2
    maxDuration: 3m

# Every hostname is <name>.<domain>. The wildcard certificate covers them all.
domain: umtdg.com

owner:
  email: me@umtdg.com

network:
  # The addresses MetalLB gives to LoadBalancer Services. Keep the node's own
  # address, 10.10.10.2, out of it.
  pool:
    name: lan
    start: 10.10.10.200
    end: 10.10.10.210
    interface: eth0
  # The ingress controller's address. It has to be inside the pool.
  ingressVIP: 10.10.10.200

ingress:
  className: nginx
  # ingress-nginx serves this certificate to every Ingress that has no
  # certificate of its own.
  wildcardSecret: wildcard-tls
  annotations:
    nginx.ingress.kubernetes.io/ssl-redirect: "true"

tls:
  issuer:
    prod: letsencrypt

storage:
  className: local-path

postgres:
  cluster: pg
  namespace: cnpg
  port: 5432
  # One database per service, under the service's name.
  #   secret:          in the postgres namespace; the database role
  #   consumer.secret: in the service's namespace; what the service logs in with
  databases:
    pfo:
      name: portfolio
      secret: pfo-db-creds
      consumer:
        secret: pfo-db
    gitea:
      name: gitea
      secret: gitea-db-creds
      consumer:
        secret: gitea-db-creds

gitea:
  namespace: gitea
  ssh:
    port: 22
```

The rule for this file: a value belongs here when more than one template
needs it, or when it has to agree with another value. A value that only one
template uses is written straight into that template.

Who uses each value:

| Value | Used by | Why |
|---|---|---|
| `repo.url`, `repo.revision` | every template except local-path | Where Argo CD reads the service charts. |
| `retry` | every template | How a failed sync is retried. |
| `domain` | argocd, ingress-nginx, gitea, pfo | The hostnames, and the wildcard certificate that covers them. |
| `owner.email` | cert-manager, gitea | The Let's Encrypt account and the Gitea admin. |
| `network.pool`, `network.ingressVIP` | metallb, ingress-nginx | MetalLB hands out addresses from the pool. ingress-nginx asks for the VIP, so the VIP must be inside the pool. |
| `ingress.className` | argocd, ingress-nginx, gitea, pfo | ingress-nginx creates the class, and the others use it. |
| `ingress.wildcardSecret` | ingress-nginx, twice | The certificate it requests and the one it serves by default must be the same. |
| `ingress.annotations` | argocd, gitea, pfo | Every Ingress redirects HTTP to HTTPS. |
| `tls.issuer.prod` | cert-manager, ingress-nginx | cert-manager creates the issuer, and the wildcard certificate uses it. |
| `storage.className` | local-path, postgres, gitea | local-path creates the class, and the volumes use it. |
| `postgres.cluster`, `.namespace`, `.port` | postgres, gitea, pfo | Where the database runs, and where gitea and pfo connect. |
| `postgres.databases` | postgres, gitea, pfo | postgres creates each database and role; the service logs in with them. |
| `gitea.namespace`, `gitea.ssh.port` | gitea, ingress-nginx | ingress-nginx forwards SSH to Gitea. |

What left `values.yaml`, and where it went:

| Old value | Now |
|---|---|
| `services`: folder, wave, namespace and sync settings of each service | In the service's template. |
| `services.<name>.host` | In the template, for example `git.{{ .Values.domain }}`. |
| `argoDefaults` | `retry` stayed. The rest is in each template. |
| `tls.issuer.staging`, `tls.resolvers`, `secrets.cloudflare` | In `templates/cert-manager.yaml`. |
| `secrets.giteaAdmin`, `services.gitea.ssh.listenPort` | In `templates/gitea.yaml`. |
| `storage.hostPath` | In `templates/local-path.yaml`. |
| `network.nodeIP` | A comment next to the pool. Only the checks used it. |
| `owner.user`, `secrets.argoRepo` | Gone. Nothing renders them. |
| `postgres.databases[].consumer.service` | The database's key, for example `postgres.databases.pfo`. |

`postgres.databases` changed from a list to a map keyed by service. That way a
template can read `.Values.postgres.databases.pfo` directly, instead of
searching the list for the right entry.

## Step 3: Write `templates/root.yaml`

Replace `templates/root.yaml` with this:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: root
  namespace: argocd
spec:
  project: default
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - ServerSideApply=true
    {{- /* No limit: Argo CD never retries a failed automatic sync of the same commit by itself, and every later wave would wait for the next commit. */}}
    retry:
      limit: -1
      refresh: true
      backoff:
        {{- toYaml .Values.retry.backoff | nindent 8 }}
  source:
    repoURL: {{ .Values.repo.url }}
    targetRevision: {{ .Values.repo.revision | quote }}
    path: .
```

Every Application in this guide has the same parts:

- **`metadata.namespace: argocd`.** Argo CD only reads Applications from its
  own namespace. It's written as `argocd` and not as a value, because it is
  fixed when Argo CD is installed. Moving it means reinstalling Argo CD.
- **`destination`** is where the rendered objects go.
  `https://kubernetes.default.svc` is the cluster Argo CD runs in. The docs
  make it a value because they deploy to many clusters; here there is one.
  `root` renders Applications, so they go to the `argocd` namespace.
- **`automated`** syncs on every new commit, without a click.
  - `prune: true`: when an object disappears from the rendered output, Argo
    CD deletes it. For `root`, deleting a template file deletes that
    Application. The Application's own objects keep running, because it has no
    finalizer.
  - `selfHeal: true`: if someone changes an object by hand, Argo CD puts it
    back the way git says.
- **`ServerSideApply=true`.** The Kubernetes API server merges the changes.
  Without it, kubectl stores a copy of each object in an annotation, and that
  fails for objects bigger than 256 KB, such as some CRDs.
- **`retry`.** The comment says why `root` never gives up. Templates show
  comments as `{{- /* ... */}}`, so they don't end up in the output.
- **`source`** is the folder to render. `path: .` is the top of the
  repository, the root chart. Argo CD finds `Chart.yaml` there and renders it
  with Helm, using `values.yaml`.

Some template syntax, used from here on:

- `{{ .Values.repo.url }}` inserts a value from `values.yaml`.
- `{{ x | quote }}` puts quotes around it. This makes YAML read the value as
  text, never as a number or a date.
- `{{- toYaml x | nindent 8 }}` inserts a whole block. `nindent 8` starts it on
  a new line and indents it by 8 spaces: the column where the block belongs.
  `{{-` removes the line break before the action, so no empty line is left.

See what it renders, and compare:

```bash
helm template homelab . -s templates/root.yaml
bash /tmp/compare.sh after root
```

**Expected difference:** the source. It was the `generated` folder with a
Helm release name; it is now `.`, with no `helm:` block. Argo CD uses the
Application's name as the release name, and our templates don't use the
release name anyway.

## Step 4: Write the first service: metallb

Each service template has two parts: the Application's settings first, then
the service chart's values. In YAML the order of keys doesn't matter, so the
values can come last, where they're easy to add.

Create `templates/metallb.yaml` with the Application part:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: metallb
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "-30"
spec:
  project: default
  destination:
    server: https://kubernetes.default.svc
    namespace: metallb-system
  syncPolicy:
    automated:
      prune: false
      selfHeal: true
    syncOptions:
      - ServerSideApply=true
      - CreateNamespace=true
      - SkipDryRunOnMissingResource=true
    managedNamespaceMetadata:
      labels:
        pod-security.kubernetes.io/enforce: privileged
        pod-security.kubernetes.io/audit: privileged
        pod-security.kubernetes.io/warn: privileged
    retry:
      {{- toYaml .Values.retry | nindent 6 }}
  source:
    repoURL: {{ .Values.repo.url }}
    targetRevision: {{ .Values.repo.revision | quote }}
    path: platform/metallb
    helm:
      valuesObject:
```

Then add the values from `platform/metallb/values.tpl.yaml`, each line
indented by 8 spaces so it sits under `valuesObject:`:

```bash
sed 's/^./        &/' platform/metallb/values.tpl.yaml >> templates/metallb.yaml
```

`^.` matches only lines that have text, so empty lines get no trailing
spaces.

The first line you added is `{{- $pool := .Values.network.pool }}`. It sets a
variable for the rest of the file and prints nothing. Move it to the very top
of the file, above `apiVersion:`, so the file starts with its variables.

What the settings do:

- **`sync-wave: "-30"`** is the first wave. MetalLB gives LoadBalancer
  Services their addresses, and ingress-nginx needs one. The wave is a string,
  so it has quotes.
- **`prune: false`.** MetalLB ships CRDs. If a CRD ever dropped out of the
  rendered chart, pruning would delete it, and with it every object of that
  kind. Every service that ships CRDs has `prune: false`.
- **`CreateNamespace=true`** lets Argo CD create `metallb-system` before the
  sync. `managedNamespaceMetadata` puts labels on that namespace. MetalLB's
  speaker uses the host's network, which only the `privileged` Pod Security
  level allows.
- **`SkipDryRunOnMissingResource=true`.** The chart creates an
  `IPAddressPool`, a kind defined by MetalLB's own CRDs. On the first sync
  those CRDs don't exist yet, so Argo CD's dry run would fail. This option
  skips the dry run for such objects. The pool also has sync wave `"1"` inside
  the chart, so Argo CD applies it after the CRDs, which are in wave 0.
- **`{{- toYaml .Values.retry | nindent 6 }}`** inserts the `retry` block from
  `values.yaml`. `retry:` is at column 4, so its content starts at 6.
- **`path: platform/metallb`** is the service chart.

Check it:

```bash
bash /tmp/compare.sh after metallb
```

It should print `No differences.` If not, lines starting with `<` are what the
old chart rendered, and lines starting with `>` are what yours renders.

## Step 5: Write the other services

Do them in wave order. That way you also see why each one comes where it does.

For each service:

1. Copy metallb's Application part into a new file:

   ```bash
   sed -n '/^apiVersion:/,/valuesObject:/p' templates/metallb.yaml > templates/<name>.yaml
   ```

2. Change `metadata.name`, the `sync-wave`, `destination.namespace` and
   `source.path` to the service's.
3. Delete the `managedNamespaceMetadata` block. Only MetalLB needs it.
4. Set `prune`, `selfHeal` and `syncOptions`. Unless the service says
   otherwise: `prune: true`, `selfHeal: true`, and the sync options
   `ServerSideApply=true` and `CreateNamespace=true`.
5. Add the values:

   ```bash
   sed 's/^./        &/' <folder>/values.tpl.yaml >> templates/<name>.yaml
   ```

6. Make the edits the service lists. Then move any `{{- $x := ... }}` lines to
   the top of the file.
7. Check it:

   ```bash
   bash /tmp/compare.sh after <name>
   ```

Why the values need edits: the old values files called helpers from
`_helpers.tpl`, such as `homelab.host`, and read `.service`, which the helpers
filled in. Both are gone. Each of those becomes a value from `values.yaml`, or
plain text when only this service uses it.

About `nindent` in the values: the number is the column where the block
starts. Everything you added is 8 columns further right than in the old file,
so `nindent 4` becomes `nindent 12`.

### local-path (wave -25)

Creates the `local-path` storage class. Its volumes are folders on the node's
disk. Postgres and Gitea need volumes, so it comes early.

- **Name** `local-path`, **wave** `"-25"`, **namespace** `local-path-storage`.
- **Delete** `SkipDryRunOnMissingResource=true`.
- **Source:** the upstream chart isn't published to a Helm repository, so
  this Application reads it straight from rancher's git repository, at a fixed
  tag. Replace the `source` block with:

  ```yaml
    source:
      repoURL: https://github.com/rancher/local-path-provisioner.git
      targetRevision: v0.0.37
      path: deploy/chart/local-path-provisioner
      helm:
        valuesObject:
  ```

- **Values** from `platform/local-path/values.tpl.yaml`. Edit:
  - Replace `{{ .Values.storage.hostPath }}` with `/mnt/data/local-path`.

The check only compares the Application. The chart itself isn't in this
repository.

### cert-manager (wave -20)

Gets certificates from Let's Encrypt. ingress-nginx asks it for the wildcard
certificate, so cert-manager comes before ingress-nginx.

- **Name** `cert-manager`, **wave** `"-20"`, **namespace** `cert-manager`,
  **path** `platform/cert-manager`.
- **`prune: false`:** it ships CRDs.
- **Keep** `SkipDryRunOnMissingResource=true`. The chart's issuers are of a
  kind that cert-manager's own CRDs define, as with MetalLB's pool.
- **Values** from `platform/cert-manager/values.tpl.yaml`. Edit:
  - Delete the line `{{- $issuer := .Values.tls.issuer }}`.
  - Replace `{{ .Values.secrets.cloudflare.name }}` with `cloudflare-api-token`.
  - Replace `{{ .Values.secrets.cloudflare.key }}` with `api-token`.
  - Replace `{{ $issuer.staging }}` with `letsencrypt-staging`.
  - Replace `{{ $issuer.prod }}` with `{{ .Values.tls.issuer.prod }}`.
  - Replace `{{ join "," .Values.tls.resolvers }}` with
    `1.1.1.1:53,9.9.9.9:53`.

### ingress-nginx (wave -15)

Receives all web traffic on the ingress VIP and passes it to the right
service. It requests the wildcard certificate and serves it.

- **Name** `ingress-nginx`, **wave** `"-15"`, **namespace** `ingress-nginx`,
  **path** `platform/ingress-nginx`.
- **Delete** `SkipDryRunOnMissingResource=true`.
- **Add** this line under `metadata.annotations`:

  ```yaml
      argocd.argoproj.io/client-side-apply-migration-manager: helm
  ```

  ingress-nginx was installed with Helm before. With this annotation, Argo CD
  takes over the fields Helm owned instead of sharing them. `MIGRATION.md`
  removes it after the switch.

- **Values** from `platform/ingress-nginx/values.tpl.yaml`. Edit:
  - Delete the line
    `{{- $gitea := include "homelab.service" (list . "gitea") | fromYaml }}`.
  - Replace `{{ .service.namespace }}/` with `ingress-nginx/`.
  - Replace the line under `tcp:` with:

    ```yaml
                {{ .Values.gitea.ssh.port | quote }}: {{ printf "%s/gitea-ssh:%v" .Values.gitea.namespace .Values.gitea.ssh.port | quote }}
    ```

    It forwards TCP port 22 on the ingress VIP to Gitea's `gitea-ssh`
    Service, so `git clone git@git.umtdg.com:...` works. `printf` fills each
    `%s` and `%v` with the values that follow, in order. The Service is called
    `gitea-ssh` because the gitea Application is called `gitea`, and Argo CD
    uses that as the Helm release name.

### cnpg (wave -10)

The CloudNativePG operator. It runs Postgres clusters described by its own
kinds, such as `Cluster`.

- **Name** `cnpg`, **wave** `"-10"`, **namespace** `cnpg-system`, **path**
  `platform/cnpg`.
- **`prune: false`:** it ships CRDs.
- **Delete** `SkipDryRunOnMissingResource=true`.
- **Values** from `platform/cnpg/values.tpl.yaml`. No edits.

### postgres (wave -5)

The Postgres cluster `pg` and its databases. These are CloudNativePG objects,
so they come after cnpg.

- **Name** `postgres`, **wave** `"-5"`, **path** `platform/postgres`.
- **Namespace** `{{ .Values.postgres.namespace }}`. gitea and pfo connect to
  this namespace, so it comes from `values.yaml`.
- **`prune: false`:** never let Argo CD delete the database.
- **Delete** `SkipDryRunOnMissingResource=true`.
- **Values** from `platform/postgres/values.tpl.yaml`. No edits. The
  `range .Values.postgres.databases` loop still works: on a map, `range` goes
  through the entries in key order.

**Expected difference:** the two databases are listed in a different order,
gitea before portfolio, because `range` sorts the keys. CloudNativePG matches
databases and roles by name, so the order doesn't matter. This is the only
difference in a service.

### pfo (wave 0)

The portfolio app. It needs its database, so it comes after postgres.

- **Name** `pfo`, **wave** `"0"`, **namespace** `default`, **path**
  `apps/pfo`.
- **Sync options:** only `ServerSideApply=true`. The `default` namespace
  always exists, so Argo CD must not create or manage it.
- **Top of the file:**

  ```yaml
  {{- $database := .Values.postgres.databases.pfo }}
  ```

- **Values** from `apps/pfo/values.tpl.yaml`. Edit:
  - Delete the line
    `{{- $database := include "homelab.databaseFor" (list . .service.name) | fromYaml }}`.
    The line at the top replaces it.
  - Replace `{{ include "homelab.postgres.address" . }}` with:

    ```
    {{ printf "%s-rw.%s.svc.cluster.local:%v" .Values.postgres.cluster .Values.postgres.namespace .Values.postgres.port }}
    ```

    CloudNativePG creates a Service called `<cluster>-rw` that always points
    at the writable primary. Writing the address as
    `{{ … }}-rw.{{ … }}.svc.cluster.local:{{ … }}` renders the same, but
    editors that highlight the YAML between the `{{ }}` see
    `-rw..svc.cluster.local:` there. A `:` at the end of a line looks like the
    start of a new key, so the highlighting breaks.
  - Replace the three lines from `{{- with .service.legacyEnvFromSecret }}` to
    `{{- end }}` with `legacyEnvFromSecret: pfo-secret`, indented like
    `credentials:`. pfo still reads its database login from the old
    `pfo-secret`. `MIGRATION.md` removes this line after the switch.
  - Replace `{{ include "homelab.host" (list . .service.name) }}` with
    `pfo.{{ .Values.domain }}`.
  - Replace `{{- include "homelab.ingress.annotations" . | nindent 4 }}` with
    `{{- toYaml .Values.ingress.annotations | nindent 12 }}`.

### gitea (wave 0)

The git server. It needs its database, like pfo.

- **Name** `gitea`, **wave** `"0"`, **path** `apps/gitea`.
- **Namespace** `{{ .Values.gitea.namespace }}`. ingress-nginx forwards SSH
  into this namespace, so it comes from `values.yaml`.
- **Delete** `SkipDryRunOnMissingResource=true`.
- **Add** the same migration annotation as ingress-nginx. Gitea was installed
  with Helm too, and its volume `gitea-shared-storage` stays in the cluster
  during the switch.
- **Top of the file:**

  ```yaml
  {{- $host := printf "git.%s" .Values.domain }}
  {{- $database := .Values.postgres.databases.gitea }}
  ```

  The hostname is used five times. The variable keeps it in one place.

- **Values** from `apps/gitea/values.tpl.yaml`. Edit:
  - Delete the three lines that set `$host`, `$database` and `$ssh`.
  - Replace `port: {{ $ssh.port }}` with `port: {{ .Values.gitea.ssh.port }}`.
  - Replace `{{- include "homelab.ingress.annotations" . | nindent 6 }}` with
    `{{- toYaml .Values.ingress.annotations | nindent 14 }}`.
  - Replace `{{ .Values.secrets.giteaAdmin.name }}` with `gitea-admin`.
  - Replace `{{ include "homelab.postgres.address" . }}` with the same
    address as in pfo.
  - Replace `{{ $ssh.port | quote }}` with
    `{{ .Values.gitea.ssh.port | quote }}`.
  - Replace `{{ $ssh.listenPort | quote }}` with `"2222"`. Gitea runs
    without root, so inside the container it can't listen on port 22. The
    Service maps port 22 to 2222.

### argocd (wave 10)

Argo CD manages itself. It already runs when `root` starts, because
`make bootstrap` installs it. This Application only keeps it up to date, so
it comes last.

- **Name** `argocd`, **wave** `"10"`, **namespace** `argocd`, **path**
  `platform/argocd`.
- **`prune: false`:** it ships CRDs, including the one for Applications.
- **`selfHeal: false`:** Argo CD doesn't undo changes to itself on its own.
  If a change breaks Argo CD, you can fix it by hand without Argo CD putting
  the broken version back.
- **Delete** `SkipDryRunOnMissingResource=true`.
- **Add** the same migration annotation as ingress-nginx.
- **Values** from `platform/argocd/values.tpl.yaml`. Edit:
  - Replace `{{ include "homelab.host" (list . .service.name) }}` with
    `argo.{{ .Values.domain }}`.
  - Replace `{{- include "homelab.ingress.annotations" . | nindent 8 }}` with
    `{{- toYaml .Values.ingress.annotations | nindent 16 }}`.

Look for `resource.customizations.health.argoproj.io_Application` in these
values. That's the health check that makes the sync waves wait.

## Step 6: Compare everything

```bash
bash /tmp/compare.sh after
```

**Expected differences:**

- `root.yaml`: the source, as in step 3.
- `postgres.yaml` and `charts/postgres.yaml`: the order of the databases, as
  in step 5.

Anything else is a mistake. The output names the file it is in.

The root chart should render ten Applications:

```bash
helm template homelab . | grep -c '^kind: Application$'
```

## Step 7: Clean up

1. Delete the old values files. Their content now lives in `templates/`:

   ```bash
   rm platform/*/values.tpl.yaml apps/*/values.tpl.yaml
   ```

2. Add these lines to the end of `.helmignore`:

   ```
   # The root chart is Chart.yaml, values.yaml and templates/ only.
   platform/
   apps/
   ```

   Helm loads every file in a chart's folder, and the root chart's folder is
   the whole repository. The old helpers read files from `platform/` and
   `apps/`. The new templates don't.

3. Update `tests/charts_test.sh`. It renders each service chart with the
   values from its Application, the same way Argo CD does, so you see a broken
   chart before you push. Change it in four places:

   - Render the whole root chart, since `applications.yaml` is gone:

     ```bash
     apps=$(helm template homelab "$ROOT") || exit 1
     ```

   - Take only Applications, and skip `root`, whose chart is the root chart
     itself:

     ```bash
     for name in $(yq -N 'select(.kind == "Application" and .spec.source.repoURL == "'"$repo"'" and .metadata.name != "root") | .metadata.name' <<<"$apps"); do
     ```

   - Delete the line `release=$(yq '.spec.source.helm.releaseName' <<<"$app")`.
     The Applications no longer set a release name.
   - Replace `helm template "$release"` with `helm template "$name"`.

4. Replace the `Makefile` with this. Lines under a target start with a tab:

   ```make
   # Directories of charts that depend on an upstream chart.
   WRAPPERS := $(patsubst %/Chart.yaml,%,$(shell grep -l '^dependencies:' platform/*/Chart.yaml apps/*/Chart.yaml))

   .PHONY: deps test bootstrap

   # Download the upstream charts named in each Chart.yaml and write Chart.lock.
   deps:
   	@for dir in $(WRAPPERS); do \
   		helm dependency update $$dir || exit 1; \
   	done

   # The root chart renders, and so does every chart its Applications point at,
   # with the values each Application gives it. Needs `make deps`.
   test:
   	helm template homelab . >/dev/null
   	tests/charts_test.sh

   # Install Argo CD with the values from templates/argocd.yaml, then hand over
   # to root. Only for a cluster where Argo CD does not manage itself yet.
   bootstrap: deps
   	helm template homelab . -s templates/argocd.yaml \
   		| yq '.spec.source.helm.valuesObject' \
   		| helm upgrade --install argocd platform/argocd -n argocd --create-namespace \
   			-f - --wait --timeout 10m
   	helm template homelab . -s templates/root.yaml | kubectl apply -f -
   ```

   `make bootstrap` installs Argo CD with the same values its Application
   uses later, including the health check. Then it applies `root`, and `root`
   creates everything else. `MIGRATION.md` explains it step by step.

5. Run the tests:

   ```bash
   make test
   ```

   Each service chart should print `OK`.

6. Update the README. It still describes the old chart. It should cover:

   - how the root chart and the service charts fit together, as in
     [How app of apps works](#how-app-of-apps-works);
   - the rule for what goes into `values.yaml`;
   - the commands: `make deps`, `make test`, `make bootstrap`;
   - the tasks in [Working with it](#working-with-it);
   - these rules:
     - Applications have no finalizers.
     - Services that ship CRDs have `prune: false`.
     - Objects that need their operator's CRDs have sync wave `"1"`.
     - Sync waves only wait because of the health check in
       `templates/argocd.yaml`.
     - Secrets are never in git.

7. Commit:

   ```bash
   git add -A
   git commit -m "refactor: plain app of apps root chart"
   ```

## Working with it

**See what Argo CD gets for a service:**

```bash
helm template homelab . -s templates/gitea.yaml
```

**See the wave order:**

```bash
grep -H sync-wave templates/*.yaml
```

**Change a shared value:** edit `values.yaml`, run `make test`, commit and
push. To see which Applications change, compare the rendered output before
and after your edit:

```bash
git stash
helm template homelab . > /tmp/old.yaml
git stash pop
helm template homelab . | diff /tmp/old.yaml -
```

**Add a service:**

1. Create its chart in `platform/<name>/` or `apps/<name>/`. For an upstream
   chart, list it under `dependencies` in `Chart.yaml`, with an exact version.
2. Copy the template of a similar service to `templates/<name>.yaml`, and
   change it as in step 5.
3. Pick a wave after everything it needs.
4. If it needs a value another template already uses, read it from
   `values.yaml`. If a value is now used by two templates, move it to
   `values.yaml`.
5. Run `make deps test`, commit and push.

**Remove a service:** delete its template. `root` deletes the Application.
Its objects keep running, because there is no finalizer. Delete them by hand
if you want them gone.

**Upgrade an upstream chart:** change the version in the service's
`Chart.yaml`, run `helm dependency update <folder>`, and commit `Chart.yaml`
and `Chart.lock` together.

## Good to know

**Values reach a service through `root`.** Each Application carries its
values, so a change takes effect when `root` applies the new Application. If
an Application in an earlier wave never becomes healthy, `root` keeps waiting
for it and doesn't pick up new commits. This happens, for example, when the
ingress VIP is outside the MetalLB pool: the ingress Service never gets an
address. Push the fix, then:

```bash
argocd app terminate-op root
```

A service that fails, instead of waiting, ends the sync. The retry then picks
up the newest commit by itself.

**A mistake in a template stops `root`.** If the root chart doesn't render,
`root` shows an error and changes nothing. Everything already running keeps
running. Fix it and push. `make test` catches this before you push.

**Try a branch** by pausing `root` first. Otherwise `root` puts the
Application back on `main`:

```bash
argocd app set root --sync-policy none
argocd app set gitea --revision my-branch
# when done
argocd app set root --sync-policy automated --self-heal --auto-prune
```

**Apply a change right away**, instead of waiting up to 3 minutes:

```bash
argocd app sync root
```

## Later: validation

These were cut to keep the first version simple. Each can come back on its
own:

- **A schema for `values.yaml`** (`values.schema.json`). Helm checks it before
  rendering, so a misspelled or missing value fails right away. With 74 lines
  of values it stays short.
- **Checks that values agree:** the ingress VIP inside the pool, and the
  node's address outside it. Today these are comments in `values.yaml`.
- **CI** that runs `make deps test` on every push.
- **Committing the rendered Applications** (`generated/`), so every commit
  shows the exact values each service gets.
- **An AppProject** that limits which repositories and namespaces the
  Applications may use.

Not validation, but also left for later:

- Pin pfo's image to a version instead of `latest`.
- Put pfo's variables straight into its Deployment, instead of a ConfigMap.
- Remove the `required` checks from the service charts' templates.

## What to do next

These are outside this guide, most important first:

1. **Replace ingress-nginx.** It has had no releases and no security fixes
   since March 2026. Gateway API is one option. Every Ingress setting already
   comes from `values.yaml`, which keeps the change small.
2. **Set up backups.** Postgres and Gitea live on one disk. A disk failure
   loses both. Back them up to storage outside the node, for example with
   CloudNativePG's backups to an S3-compatible store.
3. **Keep an offline copy of the secrets:** the Cloudflare token, the
   repository key and the database passwords. A rebuild needs all of them.
4. **Fix the smoke tests.** The `test.sh` scripts have addresses and
   hostnames written in, such as `10.10.10.200`. They could read them from
   `values.yaml` with yq instead, for example `yq .domain values.yaml`.
