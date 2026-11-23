# k8s-stack

Everything that runs on my homelab cluster. Argo CD deploys all of it from
this repo.

```
Chart.yaml, values.yaml, templates/   the root chart: one Argo CD Application per service
platform/<service>/                   stuff the cluster needs before anything else works
apps/<service>/                       the apps themselves (gitea, pfo)
tests/                                tests for the charts
```

## How it works

It's the "app of apps" setup from the Argo CD docs
([Cluster Bootstrapping](https://argo-cd.readthedocs.io/en/stable/operator-manual/cluster-bootstrapping/#app-of-apps-pattern-alternative)).

- `root` is an Argo CD Application that points at the top of this repo. The
  top of the repo is a Helm chart, the root chart.
- Every file in `templates/` is one Application, one per service. `root`
  renders the chart and creates them.
- Each of those points at a chart in `platform/` or `apps/`, and carries the
  values for it under `valuesObject`. local-path is different: its chart comes
  straight from rancher's repo.
- `templates/root.yaml` is in there too, so `root` keeps itself up to date.

```
root      renders the root chart     -> the Applications: metallb, local-path, ..., argocd, root
metallb   renders platform/metallb   -> MetalLB running in the cluster
gitea     renders apps/gitea         -> Gitea running in the cluster
...
```

When you push:

1. Argo CD checks git every 3 minutes.
2. `root` renders the root chart again. If an Application changed, it applies
   the new one.
3. That Application syncs its service with the new values.

### The order

Services come up in sync waves. `root` starts the next wave only when
everything in the one before is healthy.

| Wave | Service | Why here |
|---|---|---|
| -30 | metallb | Gives out IPs. ingress-nginx needs one. |
| -25 | local-path | Gives out volumes. postgres and gitea need them. |
| -20 | cert-manager | Gets certificates. ingress-nginx asks it for the wildcard one. |
| -15 | ingress-nginx | Takes all web traffic on the VIP. |
| -10 | cnpg | The Postgres operator. |
| -5 | postgres | The database cluster `pg`. Needs cnpg. |
| 0 | pfo, gitea | Need their databases. |
| 10 | argocd | Argo CD updating itself. It already runs, so it goes last. |

The waves only wait because of the Application health check in
`templates/argocd.yaml` (`resource.customizations.health.argoproj.io_Application`).
Argo CD doesn't have one built in. Without it, everything starts at once.

To see the order:

```bash
grep -H sync-wave templates/*.yaml
```

## values.yaml

It only has values that more than one template uses, or that have to match
each other. For example, the ingress VIP has to be inside the MetalLB pool.

If only one template uses a value, write it right in that template. If a
second template needs it later, move it to `values.yaml`.

There are no checks on `values.yaml` right now. A typo usually just renders as
an empty value, so look at what you render before you push.

## A service folder

| File | What it is |
|---|---|
| `Chart.yaml` | The service's chart. The upstream chart is a dependency, with an exact version. |
| `Chart.lock` | Written by `make deps`. Commit it. The downloaded charts in `charts/` are ignored by git. |
| `templates/` | Our own objects: the MetalLB pool, the issuers, the wildcard certificate, the Postgres cluster, pfo. |
| `test.sh`, `test.yaml` | Smoke tests against the running cluster. |
| `apply.sh`, `spec.yaml`, `legacy-values.yaml`, ... | The old install. They go away after the migration. |

The values for a service aren't in its folder. They're in
`templates/<service>.yaml`.

## Commands

You need helm and mikefarah's yq. That's the Go one, not the Python one; on
Arch it's `go-yq`.

```bash
make deps        # download the upstream charts and write Chart.lock
make test        # the root chart renders, and every service chart renders with its values (needs make deps)
make bootstrap   # install Argo CD and create root. Only for a fresh cluster
```

See what Argo CD gets for one service:

```bash
helm template homelab . -s templates/gitea.yaml
```

## Common tasks

**Change a shared value.** Edit `values.yaml`, run `make test`, commit, push.
To see what changes:

```bash
git stash
helm template homelab . > /tmp/old.yaml
git stash pop
helm template homelab . | diff /tmp/old.yaml -
```

**Add a service.**

1. Make its chart in `platform/<name>/` or `apps/<name>/`. For an upstream
   chart, add it under `dependencies` in `Chart.yaml` with an exact version.
2. Copy the template of a similar service to `templates/<name>.yaml`. Change
   the name, wave, namespace, path, sync settings and values.
3. Give it a wave after everything it needs.
4. Run `make deps test`, commit, push.

**Remove a service.** Delete its template. `root` deletes the Application, but
what it deployed keeps running, because there's no finalizer. Delete that by
hand if you want it gone.

**Upgrade an upstream chart.** Change the version in `Chart.yaml`, run
`helm dependency update <folder>`, and commit `Chart.yaml` and `Chart.lock`
together.

**Sync right now** instead of waiting up to 3 minutes:

```bash
argocd app sync root
```

**Try a branch.** Pause `root` first, or it puts everything back to `main`:

```bash
argocd app set root --sync-policy none
argocd app set gitea --revision my-branch
# when you're done
argocd app set root --sync-policy automated --self-heal --auto-prune
```

## Rules

Don't break these:

- **No finalizers on Applications.** Deleting an Application leaves its stuff
  running. With a finalizer, deleting the postgres Application would delete
  the database.
- **`prune: false` for anything that ships CRDs** (metallb, cert-manager,
  cnpg, argocd), and for postgres. Pruning a CRD deletes every object of that
  kind. For CloudNativePG that's the database.
- **Objects that need their own chart's CRDs get
  `argocd.argoproj.io/sync-wave: "1"`** (the MetalLB pool, the issuers). Their
  Application also gets `SkipDryRunOnMissingResource=true`.
- **Argo CD makes the namespaces** (`CreateNamespace=true`), not the charts.
  pfo is the exception, it lives in `default`.
- **No secrets in git.** They're made by hand, see below.

## Secrets

These are made by hand:

| Secret | Namespace | What it is |
|---|---|---|
| `repo-k8s-stack` | argocd | The SSH key Argo CD uses to read this repo. |
| `cloudflare-api-token` | cert-manager | The Cloudflare token for the DNS challenge. |
| `pfo-db-creds`, `gitea-db-creds` | cnpg | The login of each database role. Postgres makes the roles from these. |
| `pfo-db` | default | pfo's database login. |
| `gitea-db-creds` | gitea | gitea's database login. Same as the one in cnpg. |
| `gitea-admin` | gitea | gitea's admin user. |

`wildcard-tls` in ingress-nginx isn't on the list. cert-manager makes it.

Keep a copy of the Cloudflare token and the repo key somewhere outside the
cluster. A rebuild needs both.

## Rebuild from zero

Start with an empty cluster with Calico running.

1. Remove the label kubeadm puts on a single node. Without this, MetalLB never
   announces from it:

   ```bash
   kubectl label node --all node.kubernetes.io/exclude-from-external-load-balancers-
   ```

2. Make the namespaces for the secrets, and the secrets:

   ```bash
   kubectl create namespace argocd
   kubectl create namespace cert-manager
   kubectl create namespace cnpg
   kubectl create namespace gitea

   kubectl -n argocd create secret generic repo-k8s-stack \
       --from-literal=type=git \
       --from-literal=url=git@github.com:umtdg/k8s-stack.git \
       --from-file=sshPrivateKey="$HOME/.ssh/argocd_repo"
   kubectl -n argocd label secret repo-k8s-stack argocd.argoproj.io/secret-type=repository

   kubectl -n cert-manager create secret generic cloudflare-api-token \
       --from-literal=api-token="$(tr -d '[:space:]' < ~/.cloudflare-token)"

   pfo_password=$(openssl rand -hex 32)
   gitea_password=$(openssl rand -hex 32)

   kubectl -n cnpg create secret generic pfo-db-creds --type=kubernetes.io/basic-auth \
       --from-literal=username=portfolio --from-literal=password="$pfo_password"
   kubectl -n cnpg create secret generic gitea-db-creds --type=kubernetes.io/basic-auth \
       --from-literal=username=gitea --from-literal=password="$gitea_password"

   kubectl -n default create secret generic pfo-db \
       --from-literal=username=portfolio --from-literal=password="$pfo_password"
   kubectl -n gitea create secret generic gitea-db-creds --type=kubernetes.io/basic-auth \
       --from-literal=username=gitea --from-literal=password="$gitea_password"

   kubectl -n gitea create secret generic gitea-admin \
       --from-literal=username=umtdg --from-literal=password="$(openssl rand -hex 48)"
   ```

3. Install Argo CD and hand over to `root`, then watch everything come up in
   order:

   ```bash
   make bootstrap
   kubectl -n argocd get applications -w
   ```

4. When everything is healthy, delete Helm's record of Argo CD, so that only
   Argo CD manages itself from now on:

   ```bash
   kubectl -n argocd delete secret -l owner=helm,name=argocd
   ```

To get the databases back, restore them from a `pg_dump` backup, like in
[MIGRATION.md](MIGRATION.md#if-something-goes-wrong).

## When something goes wrong

**`root` waits forever.** A service in an earlier wave never gets healthy. For
example, the ingress VIP is outside the MetalLB pool, so the ingress never
gets an IP. Push a fix, then:

```bash
argocd app terminate-op root
```

**`root` shows an error and does nothing.** The root chart doesn't render. Run
`make test` to see why. Everything that already runs keeps running.

## Later

Left out for now, to keep things simple:

- checks for `values.yaml`, like a schema, or making sure the VIP is in the pool;
- CI that runs `make deps test` on every push;
- pinning pfo's image instead of using `latest`;
- replacing ingress-nginx, which hasn't had any updates since March 2026;
- backups for Postgres and Gitea to somewhere off the node.
