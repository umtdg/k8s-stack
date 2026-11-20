# Switch the cluster to Argo CD

This guide moves the cluster from the old `apply.sh` installs to Argo CD.
Follow the steps in order.

Finish `SIMPLIFICATION.md` first. This guide uses `make generate`,
`generated/` and `make bootstrap`, which that guide adds.

## Before you start

You need:

- kubectl, pointed at the cluster;
- helm 4.3 and mikefarah's yq, as in `SIMPLIFICATION.md`;
- this repository, checked out on the branch you will merge.

What happens to the cluster:

- **Kept:** Calico, the Postgres cluster `pg` with its data, Gitea's
  repositories (PVC `gitea-shared-storage`), the AppProject `homelab`, and
  every secret except one. Argo CD is upgraded in place.
- **Removed, then installed again by Argo CD:** MetalLB, local-path,
  cert-manager, ingress-nginx, the CloudNativePG operator, pfo and Gitea.
- **Downtime:** from step 3 until ingress-nginx is back, the services can't be
  reached from outside the cluster.

> [!CAUTION]
> Never delete the CloudNativePG CRDs, and never run `kubectl delete -f` on
> its release manifest. Deleting the CRD deletes the `pg` cluster and its data.
> Never delete the `cnpg` or `gitea` namespace either.

## Step 1: Prepare the repository

1. Find the pfo image that runs now:

   ```bash
   kubectl -n default get pod -l app=pfo \
       -o jsonpath='{.items[0].status.containerStatuses[0].imageID}'
   ```

   Find the version tag with the same digest. This prints the digest of a
   tag, on the `Digest:` line:

   ```bash
   docker buildx imagetools inspect umtdg/pfo:1.4.2
   ```

   Set that tag as `appVersion` in `apps/pfo/Chart.yaml`. pfo then keeps
   running the same image after the switch.

2. Stop postgres from syncing on its own, so you can check its changes first.
   In `values.yaml`, add `automated: false` to its `argo` block:

   ```yaml
     postgres:
       ...
       argo:
         prune: false
         automated: false
   ```

3. Generate and test:

   ```bash
   make generate
   make test
   make deps test-charts
   ```

4. Check that nothing in the cluster follows this repository yet:

   ```bash
   kubectl -n argocd get applications
   ```

   It should print `No resources found`.

5. Merge the branch into `main` and push. Nothing deploys yet.

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

Only the Cloudflare token is gone. Create it again:

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

This upgrades Argo CD to `platform/argocd`, with the values from
`generated/argocd.yaml`. Then it applies `generated/root.yaml`.

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

The services start in this order, each one when the one before is healthy:
metallb, local-path, cert-manager, ingress-nginx, cnpg. Then postgres, pfo,
gitea and argocd.

Until ingress-nginx is up, reach the Argo CD UI through a port forward:

```bash
kubectl -n argocd port-forward svc/argocd-server 8080:80
```

postgres does not sync on its own (step 1). It shows as Healthy and OutOfSync,
because the database already runs, so the other services don't wait for it.
Check what it would change:

```bash
argocd app diff postgres --grpc-web
```

The diff should only add Argo CD's annotations. If it removes anything under
`spec`, stop and read it first. Until you sync, the database stays as it is.

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

   Only use `make bootstrap` on an empty cluster after this.

3. Give pfo its own database secret, copied from the one Postgres uses:

   ```bash
   creds() { kubectl -n cnpg get secret pfo-db-creds -o jsonpath="{.data.$1}" | base64 -d; }
   kubectl -n default create secret generic pfo-db \
       --from-literal=username="$(creds username)" --from-literal=password="$(creds password)"
   ```

4. In `values.yaml`, remove the settings only the switch needed:

   - `automated: false` under `services.postgres.argo`;
   - `migrateFrom` under argocd, gitea and ingress-nginx;
   - `legacyEnvFromSecret` under `services.pfo`.

   Then generate, test and push:

   ```bash
   make generate
   make test
   git commit -am "chore: finish the switch to Argo CD"
   git push
   ```

   pfo restarts once and uses `pfo-db`. When it runs, delete the old secret:

   ```bash
   kubectl -n default delete secret pfo-secret
   ```

5. Delete the old install files:

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

**A database is lost.** Restore it from the backup into an empty database. For
example, for `portfolio`:

```bash
kubectl -n cnpg exec -i pg-1 -c postgres -- \
    psql -U postgres -d portfolio -v ON_ERROR_STOP=1 < "$BACKUP/portfolio.sql"
```
