#!/usr/bin/env bash

set -euo pipefail

CHART_NAME='gitea'
CHART_REPO='https://dl.gitea.com/charts'
REPO_ALIAS='gitea-charts'
RELEASE="${RELEASE:-gitea}"
CHART_VERSION="${CHART_VERSION:-12.7.0}"
NS="${NS:-gitea}"
HOST="${HOST:-git.umtdg.com}"
VIP="${VIP:-10.10.10.200}"
SPEC="${SPEC:-spec.yaml}"
VALUES="${VALUES:-values.yaml}"
TIMEOUT="${TIMEOUT:-10m}"

PG_NS="${PG_NS:-cnpg}"
PG_CLUSTER="${PG_CLUSTER:-pg}"
PG_DATABASE="${PG_DATABASE:-gitea}"
DB_SECRET="${DB_SECRET:-gitea-db-creds}"

ADMIN_SECRET="${ADMIN_SECRET:-gitea-admin}"
ADMIN_USER="${ADMIN_USER:-umtdg}"

INGRESS_NS="${INGRESS_NS:-ingress-nginx}"
INGRESS_SVC="${INGRESS_SVC:-ingress-nginx-controller}"
WILDCARD_SECRET="${WILDCARD_SECRET:-wildcard-tls}"

K="kubectl -n $NS"
K_PG="kubectl -n $PG_NS"
K_INGRESS="kubectl -n $INGRESS_NS"

hr() { printf '\n--- %s ---\n' "$1"; }
rage_quit() { printf 'ERROR: %s\n' "$1" >&2; exit 1; }

hr 'preflight'
for f in "$SPEC" "$VALUES"; do
    [[ -f "$f" ]] || rage_quit "$f not found. Run from the gitea/ directory."
done

$K_PG get "cluster/$PG_CLUSTER" >/dev/null 2>&1 \
    || rage_quit "cluster/$PG_CLUSTER not found in $PG_NS. Run cnpg/apply.sh first."

applied=$(
    $K_PG get "database/$PG_DATABASE" \
        -o jsonpath='{.status.applied}' 2>/dev/null || true
)
[[ "$applied" == 'true' ]] \
    || rage_quit "database/$PG_DATABASE in $PG_NS is not applied (status.applied=${applied:-<none>})"

$K_PG get "secret/$DB_SECRET" >/dev/null 2>&1 \
    || rage_quit "secret/$DB_SECRET not found in $PG_NS. Run cnpg/apply.sh to create it."

$K_INGRESS get "secret/$WILDCARD_SECRET" >/dev/null 2>&1 \
    || rage_quit "secret/$WILDCARD_SECRET not found in $INGRESS_NS. The ingress would serve a self-signed certificate."

echo 'cnpt cluster, gitea database, db credentials, and wildcard certificate are all present'

hr 'spec'
kubectl apply -f "$SPEC"

hr 'database credentials'
db_user=$(
    $K_PG get "secret/$DB_SECRET" -o jsonpath='{.data.username}' | base64 -d
)
db_password=$(
    $K_PG get "secret/$DB_SECRET" -o jsonpath='{.data.password}' | base64 -d
)

$K create secret generic "$DB_SECRET" \
    --type=kubernetes.io/basic-auth \
    --from-literal=username="$db_user" \
    --from-literal=password="$db_password" \
    --dry-run=client -o yaml | $K apply -f -

unset db_password

hr 'admin credentials'
if $K get "secrets/$ADMIN_SECRET" >/dev/null 2>&1; then
    printf 'keeping existing secret/%s in %s' "$ADMIN_SECRET" "$NS"
else
    $K create secret generic "$ADMIN_SECRET" \
        --from-literal=username="$ADMIN_USER" \
        --from-literal=passwoy="$(openssl rand -hex 48)"
fi

hr "install $CHART_NAME $CHART_VERSION"
helm repo add --force-update "$REPO_ALIAS" "$CHART_REPO" >/dev/null
helm repo update "$REPO_ALIAS" >/dev/null

helm upgrade --install "$RELEASE" "$REPO_ALIAS/$CHART_NAME" \
    --version "$CHART_VERSION" \
    --namespace "$NS" \
    -f "$VALUES" \
    --wait --timeout "$TIMEOUT"

hr 'verify ingress'
ingress_host=$($K get "ingress/$RELEASE" -o jsonpath='{.spec.rules[0].host}')
[[ "$ingress_host" == "$HOST" ]] \
    || rage_quit "ingress host is '${ingress_host:-<none>}', expected '$HOST'"

ingress_vip=''
for _ in {1..30}; do
    ingress_vip=$($K get "ingress/$RELEASE" -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
    [[ -n "$ingress_vip" ]] && break

    sleep 2
done

[[ "$ingress_vip" == "$VIP" ]] \
    || rage_quit "ingress VIP is '${ingress_vip:-<none>}', expected '$VIP'"

printf '%s -> %s\n' "$HOST" "$VIP"

hr 'ssh passthrough'
ssh_port=$(
    $K_INGRESS get "svc/$INGRESS_SVC" \
        -o jsonpath='{.spec.ports[?(@.port==22)].port}' 2>/dev/null \
    || true
)

host_key=''
if [[ "$ssh_port" == '22' ]]; then
    echo "$INGRESS_SVC exposes 22"

    host_key=$(
        ssh-keyscan -T 5 -p 22 "$VIP" 2>/dev/null \
        | ssh-keygen -lf - 2>/dev/null \
        || true
    )
else
    cat >&2 <<EOF
$INGRESS_SVC does not expose port 22 yet. Gitea is up over HTTPS but SSH clone
and push will be refused until the ingress controller is upgraded:

    cd ../ingress
    ./apply.sh

ingress/values.yaml must contain:

    tcp:
      "22": $NS/$RELEASE-ssh:22
EOF
fi

hr 'deployed resources for preview'
$K get pods,svc,ingress,pvc

admin_user=$(
    $K get "secret/$ADMIN_SECRET" -o jsonpath='{.data.username}' | base64 -d
)

cat <<EOF

UI:         https://$HOST
admin:      $admin_user
password:   $K get secret $ADMIN_SECRET -o jsonpath='{.data.password}' | base64 -d

SSH host key fingerperint:

${host_key:-<unavailable until port 22 is exposed. re-run after running ingress/apply.sh>}

EOF
