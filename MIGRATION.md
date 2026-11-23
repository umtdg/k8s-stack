# Switch the cluster to Argo CD

This guide moves the cluster from the old `apply.sh` installs to Argo CD.
Follow the steps in order.

Finish `SIMPLIFICATION.md` first. This guide uses its templates and
`make bootstrap`.

## Before you start

You need:

- kubectl, pointed at the cluster;
- helm and mikefarah's yq, as in `SIMPLIFICATION.md`;
- the `argocd` CLI, for steps 6 and 7;
- this repository, checked out on the branch you will merge.

What happens to the cluster:

- **Kept:** Calico, the Postgres cluster `pg` with its data, Gitea's
  repositories (PVC `gitea-shared-storage`), and every secret except one.
  Argo CD is upgraded in place.
- **Removed, then installed again by Argo CD:** MetalLB, local-path,
  cert-manager, ingress-nginx, the CloudNativePG operator, pfo and Gitea.
- **Removed for good:** the AppProject `homelab`. The new Applications use the
  built-in `default` project.
- **Downtime:** from step 3 until ingress-nginx is back, the services can't be
  reached from outside the cluster.

> [!CAUTION]
> Never delete the CloudNativePG CRDs, and never run `kubectl delete -f` on
> its release manifest. Deleting the CRD deletes the `pg` cluster and its data.
> Never delete the `cnpg` or `gitea` namespace either.

## Step 1: Prepare the repository

1. Stop postgres from syncing on its own, so you can check its changes before
   they happen. In `templates/postgres.yaml`, delete the `automated` block:

   ```yaml
     syncPolicy:
       automated:          # delete this line
         prune: false      # and this one
         selfHeal: true    # and this one
       syncOptions:
   ```

   Without `automated`, Argo CD only syncs postgres when you tell it to. It
   still shows you what a sync would change. Step 7 puts the block back.

2. Test:

   ```bash
   make deps test
   ```

3. Check that nothing in the cluster follows this repository yet:

   ```bash
   kubectl -n argocd get applications
   ```

   It should print `No resources found`.

4. Merge the branch into `main` and push. Nothing deploys yet, because `root`
   doesn't exist in the cluster.

pfo keeps the `latest` image, as it runs today.

## Step 2: Back up

Make a folder for the backups, outside the repository:

```bash
BACKUP=~/homelab-backup-$(date +%F)
mkdir -p "$BACKUP"
```

Back up both databases:

```bash
for db in portfolio gitea; do
    kubectl -n cnpg exec pg-1 -c postgres -- pg_dump -U postgres -d "$db" > "$BACKUP/$db.sql"
    grep -q 'PostgreSQL database dump complete' "$BACKUP/$db.sql" || echo "$db.sql is incomplete"
done
```

Back up Gitea:

```bash
kubectl -n gitea exec deploy/gitea -c gitea -- \
    gitea dump --type tar.gz --file /tmp/gitea-dump.tar.gz
kubectl -n gitea exec deploy/gitea -c gitea -- \
    cat /tmp/gitea-dump.tar.gz > "$BACKUP/gitea-dump.tar.gz"
```

Keep every volume on disk, even if its claim is deleted:

```bash
kubectl get pv -o name \
    | xargs -I{} kubectl patch {} -p '{"spec":{"persistentVolumeReclaimPolicy":"Retain"}}'
```

## Step 3: Remove the old installs

Remove pfo. Its secret `pfo-secret` stays:

```bash
kubectl -n default delete deploy/pfo svc/pfo ingress/pfo cm/pfo-config
```

Remove Gitea. Its volume and secrets stay:

```bash
helm -n gitea uninstall gitea
kubectl -n gitea get pvc gitea-shared-storage
```

The second command must still show the volume.

Remove ingress-nginx:

```bash
helm -n ingress-nginx uninstall ingress-nginx
```

Remove cert-manager. This also deletes its namespace and the Cloudflare token
secret; step 4 creates the secret again:

```bash
kubectl delete -f \
    https://github.com/cert-manager/cert-manager/releases/download/v1.21.2/cert-manager.yaml
```

Remove MetalLB:

```bash
kubectl delete -f \
    https://raw.githubusercontent.com/metallb/metallb/refs/tags/v0.16.1/config/manifests/metallb-native.yaml
```

Remove local-path:

```bash
kubectl delete -f \
    https://raw.githubusercontent.com/rancher/local-path-provisioner/refs/tags/v0.0.37/deploy/local-path-storage.yaml
```

Remove only the CloudNativePG operator. The `pg` cluster keeps running without
it:

```bash
kubectl -n cnpg-system delete deploy/cnpg-controller-manager
```

Why these can't simply be taken over by Argo CD:

- **MetalLB:** the chart uses other names (`metallb-controller`,
  `metallb-speaker`). The old `controller` and `speaker` would keep running next
  to the new ones, and both would hand out addresses.
- **local-path and the CloudNativePG operator:** the chart's Deployment uses a
  different selector, and Kubernetes can't change the selector of an existing
  Deployment.

The certificate secret `wildcard-tls` stays in `ingress-nginx`. cert-manager
reuses it, as long as it still matches.

## Step 4: Create the secrets

Only the Cloudflare token is gone. Create it again. Its name and key are the
ones in `templates/cert-manager.yaml`:

```bash
kubectl create namespace cert-manager
kubectl -n cert-manager create secret generic cloudflare-api-token \
    --from-literal=api-token="$(tr -d '[:space:]' < ~/.cloudflare-token)"
```

Check that the repository secret is still there. Argo CD needs it to read this
repository:

```bash
kubectl -n argocd get secret repo-k8s-stack
```

If it is missing, create it as `platform/argocd/apply.sh` does.

The other secrets stay as they are:

| Secret | Namespace |
|---|---|
| `pfo-db-creds`, `gitea-db-creds` | `cnpg` |
| `pfo-secret` | `default` |
| `gitea-db-creds`, `gitea-admin` | `gitea` |

## Step 5: Start Argo CD

```bash
make bootstrap
```

It runs these commands:

1. `make deps` downloads the upstream charts, including Argo CD's.
2. It renders `templates/argocd.yaml` and takes the values out of it:

   ```bash
   helm template homelab . -s templates/argocd.yaml | yq '.spec.source.helm.valuesObject'
   ```

   These are the values Argo CD's own Application uses later, so Argo CD
   starts out the same way it will manage itself.

3. It upgrades the Argo CD that runs now, the Helm release `argocd` that
   `apply.sh` installed, to `platform/argocd` with those values. `--wait`
   waits until the new version runs.
4. It renders `templates/root.yaml` and applies it with kubectl. This creates
   `root`. From here on, `root` creates everything else.

Check that the Application health check is installed:

```bash
kubectl -n argocd get cm argocd-cm \
    -o jsonpath='{.data.resource\.customizations\.health\.argoproj\.io_Application}'
```

It should print a short Lua script. Without it, `root` starts every service at
once instead of in order.

## Step 6: Watch the services come up

```bash
kubectl -n argocd get applications -w
```

First `root` appears. It renders the root chart and creates one Application
per file in `templates/`. Then the services start in wave order, each wave
when the one before is healthy: metallb, local-path, cert-manager,
ingress-nginx, cnpg, postgres, then pfo and gitea together, then argocd.

Until ingress-nginx is up, reach the Argo CD UI through a port forward:

```bash
kubectl -n argocd port-forward svc/argocd-server 8080:80
```

In a second terminal, log in with the CLI through that port forward. Argo CD
serves plain HTTP behind nginx, hence `--plaintext`:

```bash
argocd login localhost:8080 --plaintext --grpc-web --username admin
```

It asks for the admin password. If you never changed it,
`argocd admin initial-password -n argocd` prints it.

postgres doesn't sync on its own (step 1). It shows as Healthy and OutOfSync.
Healthy, because the database already runs, so the later waves don't wait for
it. OutOfSync, because the cluster doesn't match git yet. Check what a sync
would change:

```bash
argocd app diff postgres --grpc-web
```

What to expect:

- Argo CD adds its own annotations and labels.
- The managed roles are listed in a different order: gitea first, then
  portfolio. CloudNativePG matches roles by name, so the order changes
  nothing.

If the diff removes anything else under `spec`, stop and read it first. Until
you sync, the database stays as it is.

When the diff looks right, sync it:

```bash
argocd app sync postgres --grpc-web
```

## Step 7: Clean up

1. Delete what the old CloudNativePG install left behind:

   ```bash
   kubectl -n cnpg-system delete sa cnpg-manager
   kubectl delete clusterrolebinding cnpg-manager-rolebinding
   kubectl delete clusterrole cnpg-manager \
       cnpg-database-editor-role cnpg-database-viewer-role \
       cnpg-publication-editor-role cnpg-publication-viewer-role \
       cnpg-subscription-editor-role cnpg-subscription-viewer-role
   ```

2. Delete Helm's record of Argo CD. From now on, Argo CD updates itself from
   git:

   ```bash
   kubectl -n argocd delete secret -l owner=helm,name=argocd
   ```

   After this, only use `make bootstrap` on an empty cluster.

3. Delete the old AppProject. First check that every Application uses
   `default`:

   ```bash
   kubectl -n argocd get applications -o custom-columns=NAME:.metadata.name,PROJECT:.spec.project
   kubectl -n argocd delete appproject homelab
   ```

4. Give pfo its own database secret, copied from the one Postgres uses:

   ```bash
   creds() { kubectl -n cnpg get secret pfo-db-creds -o jsonpath="{.data.$1}" | base64 -d; }
   kubectl -n default create secret generic pfo-db \
       --from-literal=username="$(creds username)" --from-literal=password="$(creds password)"
   ```

5. Remove the settings that only the switch needed:

   - In `templates/postgres.yaml`, put the `automated` block back:

     ```yaml
       syncPolicy:
         automated:
           prune: false
           selfHeal: true
         syncOptions:
     ```

   - In `templates/ingress-nginx.yaml`, `templates/gitea.yaml` and
     `templates/argocd.yaml`, delete the line
     `argocd.argoproj.io/client-side-apply-migration-manager: helm`. Argo CD
     has taken over from Helm.
   - In `templates/pfo.yaml`, delete the line
     `legacyEnvFromSecret: pfo-secret`. pfo then logs in with `pfo-db`.

   Then test and push:

   ```bash
   make test
   git commit -am "chore: finish the switch to Argo CD"
   git push
   ```

   pfo restarts once and uses `pfo-db`. When it runs, delete the old secret:

   ```bash
   kubectl -n default delete secret pfo-secret
   ```

6. Delete the old install files:

   - `apply.sh`, `spec.yaml` and `legacy-values.yaml` in every service folder;
   - `apps/pfo/cm.yaml`, `apps/pfo/deploy.yaml` and `apps/pfo/service.yaml`;
   - `platform/cnpg/cluster.yaml`;
   - `platform/cert-manager/issuers.yaml`;
   - `platform/ingress-nginx/wildcard.yaml`;
   - this file, and the "During the migration" section of the README.

## If something goes wrong

**`root` waits forever** on a service that never becomes healthy. Push a fix,
then:

```bash
argocd app terminate-op root
```

**`root` shows an error and creates nothing.** The root chart doesn't render.
Run `make test` on your machine to see why, fix it and push.

**A database is lost.** Restore it from the backup into an empty database. For
example, for `portfolio`:

```bash
kubectl -n cnpg exec -i pg-1 -c postgres -- \
    psql -U postgres -d portfolio -v ON_ERROR_STOP=1 < "$BACKUP/portfolio.sql"
```
