# Gitea

## Deployment

Before deployment, make sure `metallb`, `ingress`, `cnpg`, and `cert-manager`
are all deployed. Then run `apply.sh` to deploy and `test.sh` to test the
deployment.

## Admin password

To get the initial admin password, run

```bash
kubectl -n gitea get secret gitea-admin -o jsonpath='{.data.password}' | base64 -d
```

### Reset admin password

```bash
kubectl -n gitea exec deploy/gitea -c gitea -- \
    gitea admin user change-password --username umtdg --password '<new password>'
```
