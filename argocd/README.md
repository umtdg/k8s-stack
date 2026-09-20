# argocd

## Deployment

Before running `apply.sh` make sure that `MetalLB`, `ingress-nginx`, and
`cert-manager` wildcard are already up. The deployment will fail if ingress
doesn't run on `10.10.10.200`.

Run `apply.sh` to deploy Argo CD. Then, to test the deployment, run `test.sh`.
`test.sh` will teardown any temporary resources used automatically. Run with
`KEEP=1 ./test.sh` to keep the resources alive for debugging.

## Viewing Admin Password

Admin password can be viewed with:

```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
    -o jsonpath='{.data.password}' | base64 -d
```

## Deploy Key

Create an SSH key for accessing the repository. This is optional for now since
the repository on Github is public but it will be necessary once we have Gitea
up and running.

```bash
ssh-keygen -t ed25519 -N ' ' -C argocd -f ~/.ssh/argocd_repo
cat ~/.ssh/argocd_repo.pub
```

Add the key as read-only on Github and re-run `apply.sh`.

Github allows a unique key per repository so it is required to create multiple
keys for multiple repositories with the above method.

## CLI

nginx terminates TLS and proxies HTTPS/1.1 so raw gRPC does not pass. CLI needs
gRPC-Web:

```bash
argocd login argo.umtdg.com --username admin --grpc-web
argocd app list --grpc-web
```

This can be set once with:

```bash
argocd login argo.umtdg.com admin --grpc-web
echo 'grpc-web: true' >> ~/.config/argocd/config
```

## Notes and Gotchas

- `server.insecure: true` is required. Without it, nginx speaks HTTPS to a
backend that redirects to HTTPS and the browser loops.
- `server.ingress.tls: false` is deliberate. No `tls:` block in nginx means that
it serves `ingress-nginx/wildcard-tls` via `default-ssl-certificate`.
- `application.resourceTrackingMethod: annotation` matters for adopting
resources that Helm already labelled. Changing it later forces a re-adoption of
everything.
- Since there is only one user (me) and no Slack targets, Dex and the
notifications controller are disabled.

## TODO

- [ ] `TODO(umtdg)`: Update wording on this document after migrating to Gitea
