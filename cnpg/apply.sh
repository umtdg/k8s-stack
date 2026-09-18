#!/usr/bin/env bash

set -euo pipefail

VERSION="${VERSION:-1.30.0}"
NS="${NS:-cnpg}"
OPERATOR_NS="${OPERATOR_NS:-cnpg-system}"
CLUSTER="${CLUSTER:-pg}"
SPEC="${SPEC:-cluster.yaml}"
TIMEOUT="${TIMEOUT:-300s}"
CRD_TIMEOUT="${CRD_TIMEOUT:-60s}"
DB_TIMEOUT="${DB_TIMEOUT:-120s}"

K='kubectl'

hr() { printf '\n--- %s ---\n' "$1"; }

create_role_secret() {
    local role="$1"
    local secret="$2"
    local app_ns="${3:-}"
    local app_secret="${4:-}"
    local password

    if $K -n "$NS" get "secret/$secret" >/dev/null 2>&1; then
        printf 'secret/%s exists in %s, keeping\n' "$secret" "$NS"
        password=$( \
            $K -n "$NS" get "secret/$secret" -o jsonpath='{.data.password}' \
            | base64 -d \
        )
    else
        password=$(openssl rand -hex 32)
        $K -n "$NS" create secret generic "$secret" \
            --type=kubernetes.io/basic-auth \
            --from-literal=username="$role" \
            --from-literal=password="$password"
    fi

    [[ -n "$app_ns" && -n "$app_secret" ]] || return 0

    if $K -n "$app_ns" get "secret/$app_secret" >/dev/null 2>&1; then
        printf 'secret/%s exists in %s, keeping\n' "$app_secret" "$app_ns"
        return 0
    fi

    # TODO: this is very Spring specific, make it more generic
    $K -n "$app_ns" create secret generic "$app_secret" \
        --from-literal=SPRING_DATASOURCE_USERNAME="$role" \
        --from-literal=SPRING_DATASOURCE_PASSWORD="$password"
}

hr "install cloudnative-pg $VERSION"
$K apply --server-side -f \
    "https://github.com/cloudnative-pg/cloudnative-pg/releases/download/v$VERSION/cnpg-$VERSION.yaml"

hr 'wait for operator'
$K -n "$OPERATOR_NS" rollout status deploy/cnpg-controller-manager --timeout="$TIMEOUT"

hr 'wait for webhook service endpoints'
for _ in {1..60}; do
    if $K -n "$OPERATOR_NS" get endpointslice \
        -l kubernetes.io/service-name=cnpg-webhook-service \
        -o jsonpath='{.items[*].endpoints[*].addresses[*]}' 2>/dev/null \
        | grep -q .; then

        break
    fi

    sleep 2
done

hr 'wait for CRDs'
for crd in clusters.postgresql.cnpg.io databases.postgresql.cnpg.io; do
    $K wait --for=condition=Established "crd/$crd" --timeout="$CRD_TIMEOUT"
done

hr 'role secrets'
create_role_secret portfolio pfo-db-creds default pfo-secret
create_role_secret gitea gitea-db-creds

hr 'cluster and databases'
$K apply -f "$SPEC"

hr 'wait for cluster Ready'
$K -n "$NS" wait --for=condition=Ready "cluster/$CLUSTER" --timeout="$TIMEOUT"

hr 'wait for databases'
for db in portfolio gitea; do
    $K -n "$NS" wait --for=jsonpath='{.status.applied}'=true \
        "database/$db" --timeout="$DB_TIMEOUT"
done

hr 'done'
$K -n "$NS" get cluster,database,svc,pvc

cat <<EOF
Connection string for in-cluster apps:

    jdbc:postgresql://pg-rw.$NS.svc.cluster.local:5432/portfolio

The generated credentials are in secret/pfo-secret (namespace default)
as SPRING_DATASOURCE_USERNAME and SPRING_DATASOURCE_PASSWORD.
EOF

