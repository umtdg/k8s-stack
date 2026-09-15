#!/usr/bin/env bash

set -euo pipefail

here="$(realpath "$(dirname "${BASH_SOURCE[0]}")")"

CHART_NAME='ingress-nginx'
CHART_VERSION="${CHART_VERSION:-4.15.1}"
VIP="${VIP:-10.10.10.200}"
TIMEOUT="${TIMEOUT:-5m}"
NS="${NS:-$CHART_NAME}"
K="kubectl -n $NS"

helm repo add "$CHART_NAME" https://kubernetes.github.io/"$CHART_NAME" >/dev/null
helm repo update "$CHART_NAME" >/dev/null

helm upgrade --install "$CHART_NAME" "$CHART_NAME"/"$CHART_NAME" \
    --namespace "$NS" --create-namespace \
    --version "$CHART_VERSION" \
    -f "$here/values.yaml" \
    --wait --timeout $TIMEOUT

declare ingress_vip
ingress_vip=$($K get svc "$CHART_NAME-controller" -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

[[ "$ingress_vip" == "$VIP" ]] || {
    echo "ingress VIP is '${ingress_vip:-<none>}', expected '$VIP'" >&2
    exit 1
}

printf '%s %s on %s\n' "$CHART_NAME" "$CHART_VERSION" "$VIP"
