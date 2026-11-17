# Simplification plan

The deployment should be readable file by file: what a file says is what
reaches the cluster. Today a value passes through two template engines before
it gets there, and most of the mistakes found in review sat between those
layers.

The rule this plan follows: **Helm only where an upstream chart is pulled in;
plain YAML everywhere else. A value is written where it is used.**

Where things stand:

- 505 template actions and 22 helpers across the root chart, the
  `values.tpl.yaml` files and the service templates.
- About 1,200 lines exist only to generate, validate and test the generation:
  `templates/`, `values.yaml`, `values.schema.json`, `tests/validate_test.sh`,
  `tests/style_test.sh` and the README's conventions.
- One typo in any service's values file stops `root` from rendering every
  Application.

## Summary

Ordered by how much each change reduces what can go wrong unnoticed.

| # | Change | Removes | Gives up | Breaks on the cluster | Recommendation |
|---|---|---|---|---|---|
| 1 | Plain `values.yaml` per chart | the `tpl` layer; 368 lines of values become plain YAML | one place per shared value | nothing | do |
| 2 | Plain Application manifests | the root chart: helpers, catalog, schema, validation | `managed`, `argoDefaults`, catalog checks | `root` changes source | do |
| 3 | Own templates as plain YAML | `required`, helpers, the pfo and postgres charts | a few error messages | pfo rolls once | do |
| 4 | Drop `homelab-config` | 67 lines, `make config` | nothing in use | nothing | do |
| 5 | Tests and tooling | 256 lines of tests, 4 make targets | negative tests, style checks | nothing | do |
| 6 | README | about 100 lines | nothing | nothing | do |
| 7 | After the switch | migration-only settings | nothing | pfo rolls once | do after the switch |

Items 1 to 6 land before the switch, so the cluster is switched once, onto the
final layout. Each item leaves `make test` passing.

## What stays

- Wrapper charts with the upstream chart as a pinned dependency, and
  `Chart.lock`. Argo CD builds the dependencies itself.
- Sync waves that wait for the Applications before them to be healthy, with
  the Application health check in Argo CD's values.
- Every sync setting in use today: server-side apply, retry, `prune: false`
  for services that ship CRDs, `selfHeal: false` for Argo CD,
  `SkipDryRunOnMissingResource` for metallb and cert-manager, the PSA labels
  on `metallb-system`.
- `root` managing itself; the `homelab` AppProject with orphan warnings.
- An offline `make test` that renders every chart.
- Secrets created by hand, never in git.
- The per-service `test.sh` smoke tests. They test the cluster, not the
  repository.

## Ease of deployment, before and after

| Task | Today | After |
|---|---|---|
| Bootstrap | render Argo CD's values from the root chart, `helm upgrade`, render `root`, `kubectl apply` | `helm upgrade --install argocd platform/argocd`, `kubectl apply -f root/root.yaml` |
| Add a service | directory, `Chart.yaml`, `values.tpl.yaml`, catalog entry (and schema if it has new keys) | directory, `Chart.yaml`, `values.yaml`, `root/<name>.yaml` copied from a neighbour |
| See what a service gets | `helm template … \| yq … valuesObject` | open its `values.yaml` |
| Stop managing a service | `managed: false` | delete `root/<name>.yaml` |
| Add a database | one list entry | a role, a `Database` object and the consumer's values: 3 places, 2 directories |
| Change the domain | 1 line | 11 lines in 5 files, found with `grep -rln umtdg.com` |
| Upgrade a chart | version in `Chart.yaml`, `make deps` | same |

The last rows are the cost. Shared values have not changed since the cluster
was built.

## 1. Plain `values.yaml` per chart

**Today.** The root chart reads each `values.tpl.yaml` as a string, renders it
with `tpl` against a hand-built scope, parses the result and writes it into the
Application's `valuesObject`. Argo CD then renders the service chart, which
passes the values to the upstream chart.

**Change.** Each `values.tpl.yaml` becomes a `values.yaml` with every
expression replaced by its value. Helm and Argo CD load a chart's `values.yaml`
by themselves, so the Applications no longer need `valuesObject`. The one
exception is local-path (see item 2).

**Why first.** Every rendering bug found in review was in this layer: undefined
`$ssh` and `$host`, the leftover `hl.component`, databases not forwarded to the
postgres chart, and an annotation duplicated by a one-line helper. A failing
`tpl` prints the whole values file as one escaped string.

**Gives up** one place per shared value. Counted on today's rendered values:

| Value | Files | Lines |
|---|---|---|
| domain | argocd, cert-manager, gitea, ingress-nginx, pfo | 11 |
| ingress class | argocd, gitea, ingress-nginx, pfo | 5 |
| storage class | gitea, local-path, postgres | 3 |
| issuer names | cert-manager, ingress-nginx | 3 |
| gitea SSH port | gitea, ingress-nginx | 3 |
| database secret | gitea, postgres | 3 |
| ingress VIP | ingress-nginx, metallb | 2 |
| Postgres host | gitea, pfo | 2 |
| owner e-mail | cert-manager, gitea | 2 |

**Breaking changes.** None on the cluster if every chart renders the same as
before (see [Verification](#verification)). In the repository, the
`homelab.*` helpers can no longer be used in values, and the README's rules for
values files go.

**How.** Write each Application's current values into its chart, using the
snapshot from [Verification](#verification), then copy the comments back by
hand from `values.tpl.yaml`, because yq does not carry them:

```bash
yq 'select(.metadata.name == "gitea") | .spec.source.helm.valuesObject' \
    /tmp/before/applications.yaml > apps/gitea/values.yaml
```

## 2. Plain Application manifests; the root chart goes

**Today.** `values.yaml` holds a catalog. `homelab.service` merges
`argoDefaults` into each entry, `applications.yaml` loops over the result,
`project.yaml` works out its source repositories and orphan exceptions, and
`_validate.tpl` with `values.schema.json` checks the catalog. `root` renders
all of it as a Helm chart.

**Change.** Each Application is written out in its own file, in a directory
that `root` syncs as plain YAML (a directory source, no Helm). `root.yaml` and
`project.yaml` sit next to them. A file is what `make render` prints today,
about 33 lines:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: gitea
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "0"
spec:
  project: homelab
  source:
    repoURL: git@github.com:umtdg/k8s-stack.git
    path: apps/gitea
    targetRevision: main
  destination:
    server: https://kubernetes.default.svc
    namespace: gitea
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - ServerSideApply=true
      - CreateNamespace=true
    retry:
      limit: 5
      backoff:
        duration: 10s
        factor: 2
        maxDuration: 3m
```

`grep sync-wave root/*.yaml` shows the order.

**Removes** `Chart.yaml`, `values.yaml`, `values.schema.json`, `.helmignore` and
all of `templates/`: about 890 lines, and every helper. The new files add about
400 lines with no template actions.

**Gives up:**

- **`managed`.** An Application exists when its file exists. Deleting the file
  makes `root` prune the Application. It has no finalizer, so what it deployed
  stays, the same as `managed: false` today.
- **`argoDefaults`.** The sync policy is repeated in every file, about 12 lines
  each. Argo CD has no project-wide sync defaults; the copies are explicit and
  can be searched.
- **`render.all` and `make render`.** The files are the rendering.
- **Catalog checks** from the schema and `_validate.tpl`: VIP inside the pool,
  node IP outside it, no hostname or directory twice, database names and
  secrets unique, unknown keys. What is left: the VIP and the pool are two
  lines in two files, ingress-nginx's admission webhook rejects a second
  Ingress for the same host and path, and Argo CD reports a path that does not
  exist. Pinned chart versions keep a one-line check (item 5).

**Considered and not recommended:** a 30-line root chart that loops over a
plain list, with no defaults, `tpl` or validation. It has fewer lines, but each
Application still only exists after rendering, and one template error still
blocks all of them.

**Breaking changes:**

- **`root` changes source** from a Helm chart at `.` to a directory. Before
  the switch nothing live changes. After the switch, `root` syncs itself onto
  the new source; the child Applications stay the same as long as the files
  match today's rendered output.
- **Bootstrap changes.** `MIGRATION.md` step 3 becomes
  `helm upgrade --install argocd platform/argocd -n argocd --create-namespace`.
  Step 5 becomes `kubectl apply -f root/root.yaml`, and the `managed` flip goes
  away.
- **local-path stays the exception.** Its chart is only published in git, so
  it cannot be a dependency of a wrapper chart, and its 15 lines of values stay
  inline as `helm.valuesObject` in `root/local-path.yaml`.

**How.** Generate the files once from today's output, then fix up local-path,
`root.yaml` and `project.yaml` by hand:

```bash
mkdir root
helm template homelab . --set render.all=true -s templates/applications.yaml \
    | yq -s '"root/" + .metadata.name' \
        'with(select(.metadata.name != "local-path"); del(.spec.source.helm.valuesObject)) | ... head_comment=""'
# yq names the files .yml; rename them to .yaml
```

## 3. Own templates as plain YAML

**Today.** The MetalLB pool, the ClusterIssuers, the wildcard certificate, the
Postgres cluster and the pfo chart read their values through `required`,
`range`, `with` and helpers (`postgres.protect`, `pfo.config`,
`pfo.selector`).

**Change.** Each of these values is used once, so the values layer adds
nothing. Write the objects out:

- **`platform/metallb/templates/pool.yaml`,
  `platform/cert-manager/templates/issuers.yaml`,
  `platform/ingress-nginx/templates/wildcard.yaml`:** literal YAML. Helm passes
  a file with no `{{` through unchanged. The upstream values stay in
  `values.yaml` under the chart's name.
- **`platform/postgres`:** no chart. Plain manifests for the Cluster and one
  `Database` per database, synced as a directory.
- **`apps/pfo`:** no chart. A Deployment, a Service and an Ingress. The
  environment variables go inline in the Deployment instead of a ConfigMap, so
  changing one rolls the pods by itself. Today the `checksum/config`
  annotation does that.

**Gives up:**

- **`required` error messages.** These charts only ever get values from this
  repository.
- **The postgres `range`** that keeps the role list and the `Database` objects
  in step. Adding a database means two blocks in one directory.
- **pfo's `legacyEnvFromSecret` switch.** It becomes a line to edit, and goes
  in item 7 anyway.

**Breaking changes:**

- **pfo:** ConfigMap `pfo-config` is pruned and the variables move into the
  Deployment, which rolls the pods once.
- **postgres and pfo:** their Applications change from a Helm source to a
  directory source.
- Nothing else changes if the output renders the same.

## 4. Drop `homelab-config`

Nothing reads the ConfigMap: no script, chart or README step uses its keys. It
costs 67 lines of template, `make config`, and the README's rules for naming
the keys. It goes with item 2 anyway; it is listed on its own in case item 2
is not taken.

**Breaking changes.** None before the switch. After it, `root` prunes the
ConfigMap.

## 5. Tests and tooling

**Today:**

- `tests/validate_test.sh` (186 lines) tests the validator and the schema.
- `tests/style_test.sh` (70 lines) checks whitespace rules in the templates.
- `tests/charts_test.sh` renders each chart with its `valuesObject`.
- The Makefile has `validate`, `test`, `deps`, `test-charts`, `render` and
  `config`.

**Change:**

- **Delete** `validate_test.sh` and `style_test.sh`. What they test is gone
  after items 2 and 3.
- **`charts_test.sh`** runs `helm template` on every directory that has a
  `Chart.yaml`, and parses every plain manifest under `root/`,
  `platform/postgres` and `apps/pfo` with yq.
- **Version pins:** one line that fails on `^`, `~`, `*` or `x` in a
  dependency version.
- **Makefile:** `deps` and `test`.
- **Optional:** run kubeconform with `-strict` on the rendered output. It
  catches misspelled fields in manifests, but not in Helm values or
  annotations. It needs the binary, and network access for the CRD schemas
  (MetalLB, cert-manager, CloudNativePG, Argo CD).

**Gives up** the negative tests and the style checks.

No automated check catches a misspelled Helm values key (`volumeBindingNode`)
or annotation key (`argocd.argproj.io`). After this plan they sit in short,
plain files, which is where review catches them.

**Breaking changes.** None.

## 6. README

Cut "Conventions" (82 lines) and "Where a value lives". Keep the layout, the
bootstrap, adding a service, upgrading a chart, and these rules:

- no finalizers on Applications;
- `prune: false` for services that ship CRDs;
- sync wave `"1"` for objects that need their operator running;
- waves wait for health, which needs Argo CD's values;
- namespaces are created by Argo CD;
- secrets are never in git.

The target is about 100 lines.

## 7. After the switch

- **Migration annotations:** remove the
  `client-side-apply-migration-manager: helm` annotation from the argocd,
  gitea and ingress-nginx Applications. It only matters for the first sync
  that takes over from Helm.
- **pfo's credentials:** create `default/pfo-db`, point the Deployment at it,
  then delete `pfo-secret`. The pods roll once, and the secret has to exist
  first.
- **Legacy files:** delete them and `MIGRATION.md`; `MIGRATION.md` already
  lists them.
- **Keep** `fullnameOverride: cnpg-controller-manager`. Changing it would
  rename the operator's Deployment again.

## Verification

Before starting, render every chart with the values its Application passes
today:

```bash
mkdir -p /tmp/before
helm template homelab . --set render.all=true -s templates/applications.yaml \
    > /tmp/before/applications.yaml
for app in $(yq -N 'select(.spec.source.path | test("^(platform|apps)/")) | .metadata.name' \
        /tmp/before/applications.yaml); do
    a=$(yq "select(.metadata.name == \"$app\")" /tmp/before/applications.yaml)
    yq '.spec.source.helm.valuesObject // {}' <<<"$a" \
        | helm template "$app" "$(yq .spec.source.path <<<"$a")" \
            -n "$(yq .spec.destination.namespace <<<"$a")" -f - \
        | yq -P 'sort_keys(..) | ... comments=""' > "/tmp/before/$app.yaml"
done
```

After each item, render the same way and `diff`. For directories that are now
plain manifests, use `yq -P 'sort_keys(..) | ... comments=""' <dir>/*.yaml`.

The only expected differences are pfo in item 3 (the ConfigMap gone, the
variables inline) and the `valuesObject` and `homelab-config` removals in the
Applications.

## Open decisions

1. **Name of the Applications directory:** `root/`, `argocd/apps/` or
   `clusters/homelab/`. This plan uses `root/`.
2. **pfo:** plain manifests (recommended) or a minimal chart.
3. **postgres:** written out (recommended) or a `range` over a list.
4. **kubeconform** in `make test`: yes or no.

## End state

```
root/                    one Application per service, plus root.yaml and project.yaml
platform/<service>/      Chart.yaml, Chart.lock, values.yaml; templates/ only for extra objects
platform/postgres/       Cluster and Database manifests
apps/gitea/              Chart.yaml, Chart.lock, values.yaml
apps/pfo/                Deployment, Service and Ingress manifests
tests/charts_test.sh
Makefile                 deps, test
README.md
```

## Out of scope

- **ingress-nginx** has been unmaintained since March 2026: no releases and no
  CVE fixes. Replacing it, for example with Gateway API, is a separate change.
  It is easier after this plan, since every Ingress is then one plain block in
  one file.
- **Calico** stays outside Argo CD.
