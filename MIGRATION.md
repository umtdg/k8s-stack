# Switching to the charts

The order of the switch from the `apply.sh` installs to Argo CD. Delete this
file once every service is synced; [After the switch](#6-after-the-switch)
lists what goes with it.

Every command runs from the repository root, with kubectl pointed at the
cluster, helm, and yq (mikefarah, v4).

## What survives

| What | Where | How |
|---|---|---|
| Calico | `tigera-operator`, `calico-system` | not touched |
| Postgres | Cluster `pg`, its PVC and both `Database` objects in `cnpg` | adopted in place by `postgres` |
| Gitea repositories | PVC `gitea-shared-storage` in `gitea` | kept by `helm.sh/resource-policy: keep`, adopted by `gitea` |
| Argo CD | `argocd` | upgraded in place to `platform/argocd` |
| Secrets | `cnpg`, `gitea`, `default`, `argocd` | not touched |

Everything else is removed and installed again by Argo CD. Nothing outside
the cluster can reach it from step 2 until `ingress-nginx` is synced.

Never delete the CloudNativePG CRDs, and never `kubectl delete -f` its release
manifest: deleting the `clusters.postgresql.cnpg.io` CRD deletes `pg`, and
with it the PVC that holds the data. Never delete the `cnpg` or `gitea`
namespace either.

## 1. Before anything is removed

`make test` and `make deps test-charts` pass, and this branch is merged and
pushed to `main`: `root` renders `repo.revision`.

Back up both databases and Gitea, outside the repository:

```bash
BACKUP=~/homelab-backup-$(date +%F)
mkdir -p "$BACKUP"

for db in portfolio gitea; do
    kubectl -n cnpg exec pg-1 -c postgres -- pg_dump -U postgres -d "$db" > "$BACKUP/$db.sql"
    grep -q 'PostgreSQL database dump complete' "$BACKUP/$db.sql" || echo "$db.sql is truncated"
done

kubectl -n gitea exec deploy/gitea -c gitea -- \
    gitea dump --type tar.gz --file /tmp/gitea-dump.tar.gz
kubectl -n gitea exec deploy/gitea -c gitea -- \
    cat /tmp/gitea-dump.tar.gz > "$BACKUP/gitea-dump.tar.gz"
```

Keep every volume on disk if its claim goes away:

```bash
kubectl get pv -o name \
    | xargs -I{} kubectl patch {} -p '{"spec":{"persistentVolumeReclaimPolicy":"Retain"}}'
```

## 2. Remove what is installed again

```bash
kubectl -n default delete deploy/pfo svc/pfo ingress/pfo cm/pfo-config

helm -n gitea uninstall gitea
kubectl -n gitea get pvc gitea-shared-storage

helm -n ingress-nginx uninstall ingress-nginx

kubectl delete -f \
    https://github.com/cert-manager/cert-manager/releases/download/v1.21.2/cert-manager.yaml

kubectl delete -f \
    https://raw.githubusercontent.com/metallb/metallb/refs/tags/v0.16.1/config/manifests/metallb-native.yaml

kubectl delete -f \
    https://raw.githubusercontent.com/rancher/local-path-provisioner/refs/tags/v0.0.37/deploy/local-path-storage.yaml

kubectl -n cnpg-system delete deploy/cnpg-controller-manager
```

Why these cannot be adopted in place:

- **MetalLB**: the chart names its workloads `metallb-controller` and
  `metallb-speaker`. The manifest's `controller` and `speaker` are not tracked
  by Argo CD and would keep running next to them, both handing out the pool.
- **local-path, the CloudNativePG operator**: the chart's Deployment selector
  differs from the manifest's, and a selector cannot change in place. Only
  the operator's Deployment goes; `pg` keeps running without it.

Deleting the cert-manager manifest deletes its namespace, and
`cloudflare-api-token` with it. `wildcard-tls` stays in `ingress-nginx`;
cert-manager reuses it as long as it still matches the Certificate.

## 3. Argo CD

Upgrade the release in place with the values Argo CD will manage it with. They
carry the health check for Applications; without it, `root` creates every
Application at once instead of wave by wave.

```bash
make deps

helm template homelab . --set render.all=true -s templates/applications.yaml \
    | yq 'select(.metadata.name == "argocd") | .spec.source.helm.valuesObject' \
    | helm upgrade --install argocd platform/argocd -n argocd --create-namespace \
        -f - --wait --timeout 10m

kubectl -n argocd get cm argocd-cm \
    -o jsonpath='{.data.resource\.customizations\.health\.argoproj\.io_Application}'
kubectl -n argocd get secret repo-k8s-stack
```

The first `get` prints the Lua health check. If the repository secret is
missing, create it as `platform/argocd/apply.sh` does.

Until `ingress-nginx` is synced, the UI is only reachable through
`kubectl -n argocd port-forward svc/argocd-server 8080:80`.

## 4. Secrets

The charts refer to these by name and never create them.

| Secret | Namespace | After step 2 |
|---|---|---|
| `cloudflare-api-token`, key `api-token` | `cert-manager` | gone |
| `pfo-db-creds`, `gitea-db-creds` | `cnpg` | kept |
| `pfo-secret` | `default` | kept |
| `gitea-db-creds`, `gitea-admin` | `gitea` | kept |
| `repo-k8s-stack` | `argocd` | kept |

```bash
kubectl create namespace cert-manager
kubectl -n cert-manager create secret generic cloudflare-api-token \
    --from-literal=api-token="$(tr -d '[:space:]' < ~/.cloudflare-token)"
```

`CreateNamespace=true` does nothing to a namespace that already exists.

## 5. Hand the services to Argo CD

In `values.yaml`, set `argoDefaults.managed: true` and
`services.postgres.argo.automated: false`, so that the adoption of `pg` is a
diff read before it is applied. Commit and push to `main`.

```bash
helm template homelab . -s templates/root.yaml | kubectl apply -f -
kubectl -n argocd get applications -w
```

`root` syncs metallb, local-path, cert-manager, ingress-nginx and cnpg in that
order, each once the one before is healthy, then waits at `postgres`:

```bash
argocd app diff postgres --grpc-web
argocd app sync postgres --grpc-web
```

The diff should only add Argo CD's annotations. If it removes anything under
`spec`, stop and read it before syncing. After `postgres`, pfo and gitea sync,
then argocd itself.

## 6. After the switch

- Delete what the manifest install of CloudNativePG left behind:

  ```bash
  kubectl -n cnpg-system delete sa cnpg-manager
  kubectl delete clusterrolebinding cnpg-manager-rolebinding
  kubectl delete clusterrole cnpg-manager \
      cnpg-database-editor-role cnpg-database-viewer-role \
      cnpg-publication-editor-role cnpg-publication-viewer-role \
      cnpg-subscription-editor-role cnpg-subscription-viewer-role
  ```

- Delete Helm's record of Argo CD, so nothing upgrades it outside Argo CD:
  `kubectl -n argocd delete secret -l owner=helm,name=argocd`.
- Remove `services.postgres.argo.automated: false`.
- Delete `apply.sh`, `spec.yaml` and `legacy-values.yaml` in each service
  directory, the manifests they applied (`apps/pfo/{cm,deploy,service}.yaml`,
  `platform/cnpg/cluster.yaml`, `platform/cert-manager/issuers.yaml`,
  `platform/ingress-nginx/wildcard.yaml`), this file, and the
  "During the migration" section of the README.
- `pfo` still reads its credentials from `pfo-secret`
  (`services.pfo.legacyEnvFromSecret`). To drop it, create `default/pfo-db`
  with the `username` and `password` of `cnpg/pfo-db-creds`, then remove
  `legacyEnvFromSecret`.

If a database is lost, restore its dump the way `platform/cnpg/migrate.sh`
does: as `postgres`, with `PGOPTIONS="-c role=<owner>"`, so every restored
object belongs to the owner.
