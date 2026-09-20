#!/usr/bin/env bash

set -euo pipefail

CHART_NAME='argo-cd'
CHART_REPO='https://argoproj.github.io/argo-helm'
RELEASE="${RELEASE:-argocd}"
CHART_VERSION="${CHART_VERSION:-10.9.2}"
NS="${NS:-argocd}"
HOST="${HOST:-argo.umtdg.com}"
VIP="${VIP:-10.10.10.200}"
SPEC="${SPEC:-spec.yaml}"
VALUES="${VALUES:-values.yaml}"
TIMEOUT="${TIMEOUT:-5m}"

REPO_URL="${REPO_URL:-git@github.com:umtdg/k8s-stack.git}"
REPO_NAME="${REPO_NAME:-k8s-stack}"
REPO_KEY_FILE="${REPO_KEY_FILE:-$HOME/.ssh.argocd_repo}"

K="kubectl -n $N"

hr() { printf '\n--- %s ---\n' "$1"; }

hr "install $CHART_NAME $CHART_VERSION"
helm repo add argo "$CHART_REPO" >/dev/null
helm repo update argo >/dev/null

helm upgrade --install "$RELEASE" "argo/$CHART_NAME" \
    --namespace "$NS" --create-namespace \
    --version "$CHART_VERSION" \
    -f "$VALUES" \
    --wait --timeout "$TIMEOUT"

resource="sts/$RELEASE-application-controller"
hr "wait for $resource"
$K rollout status "$resource" --timeout="$TIMEOUT"
printf '%s: OK\n' "$resource"

for d in server repo-server applicationset-controller redis; do
    resource="deploy/$RELEASE-$d"
    hr "wait for $resource"
    $K rollout status "$resource" --timeout="$TIMEOUT"
    printf '%s: OK\n' "$resource"
done

hr 'verify ingress'
ingres_host=$($K get "ingress/$RELEASE-server" -o jsonpath='{.spec.rules[0].host}')
[[ "$ingress_host" == "$HOST" ]] || {
    printf "ingress host is '%s', expected '%s'" "${ingress_host:-<none>}" "$HOST" >&2
    exit 1
}

ingress_vip=$($K get "ingress/$RELEASE-server" -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
[[ "$ingress_vip" == "$VIP" ]] || {
    printf "ingress VIP is '%s', expected '%s'" "${ingress_vip:-<none>}" "$VIP" >&2
    exit 1
}

hr 'repository credentials'
if [[ -r "$REPO_KEY_FILE" ]]; then
    $K create secret generic "repo-$REPO_NAME" \
        --from-literal=type=git \
        --from-literal=name="$REPO_NAME" \
        --from-literal=url="$REPO_URL" \
        --from-file=sshPrivateKey="$REPO_KEY_FILE" \
        --dry-run=client -o yaml | $K apply -f -

    $K label "secret/repo-$REPO_NAME" \
        argocd.argoproj.io/secret-type=repository --overwrite
else
    cat >&2 <<EOF
Skipping repo key secret due to missing key file '$REPO_KEY_FILE'.

Generate one and register the public key in Github repository as read-only:

    ssh-keygen -t ed25519 -N ' ' -C argocd -f $REPO_KEY_FILE
    cat $REPO_KEY_FILE

Then re-run this script.
EOF
fi

hr 'app project'
sed "s|REPO_URL|$REPO_URL|g" "$SPEC" | $K apply -f -

hr 'deployed resources for preview'
$K get pods,ingress,appproject

admin_pw=$( \
    $K get secret argocd-initial-admin-secret \
        -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || true
)

cat <<EOF

UI:         https://$HOST
user:       admin
password:   ${admin_pw:<initial secret already deleted>}

The CLI needs --grpc-web because ingress-nginx terminates TLS and does not
proxy raw gRPC on this ingress. Make it permanent:

    argocd login $HOST --username admin --grpc-web
    echo 'grpc-web: true' >> ~/.config/argocd/config

Delete secret/argocd-initial-admin-secret after changing the password:

    argocd account update-password --grpc-web
    $K delete secret argocd-initial-admin-secret

EOF
