#!/usr/bin/env bash

set -euo pipefail

VERSION="${VERSION:-v1.21.2}"
NS="${NS:-cert-manager}"
ACME_EMAIL="${ACME_EMAIL:-me@umtdg.com}"
CF_TOKEN_FILE="${CF_TOKEN_FILE:-$HOME/.cloudflare-token}"
RESOLVERS="${RESOLVERS:-1.1.1.1:53,9.9.9.9:53}"
TIMEOUT="${TIMEOUT:-180s}"

K='kubectl'

hr() { printf '\n--- %s ---\n' "$1"; }

hr 'token'
if [[ -n "${CF_API_TOKEN:-}" ]]; then
    token="$CF_API_TOKEN"
elif [[ -r "$CF_TOKEN_FILE" ]]; then
    token=$(tr -d '[:space:]' < "$CF_TOKEN_FILE")
else
    printf 'no token: set CF_API_TOKEN or create %s\n' "$CF_TOKEN_FILE" >&2
    exit 1
fi

hr 'verify cloudflare token'
verify=$( \
    curl -sS -H "Authorization: Bearer $token" \
    https://api.cloudflare.com/client/v4/user/tokens/verify
)

printf '%s\n' "$verify"
grep -q '"success":true' <<<"$verify" || { echo 'token rejected' >&2; exit 1; }

hr "install cert-manager $VERSION"
$K apply -f \
    "https://github.com/cert-manager/cert-manager/releases/download/$VERSION/cert-manager.yaml"

K="$K -n $NS"

hr 'wait for rollout'
for d in cert-manager cert-manager-webook cert-manager-cainjector; do
    $K -n "$NS" rollout status "deploy/$d" --timeout="$TIMEOUT"
done

hr 'pin dns01 recursive nameservers'
if $K get deploy cert-manager -o jsonpath='{.spec.template.spec.containers[0].args}' \
    | grep -q 'dns01-recursive-nameservers-only'; then
    echo 'already set, skipping'
else
    $K patch deploy cert-manager --type=json -p "$(cat <<EOF
[
    {
        "op": "add",
        "path": "/spec/template/spec/containers/0/args/-",
        "value": "--dns01-recursive-nameservers-only",
    },
    {
        "op": "add",
        "path": "/spec/template/spec/containers/0/args/-",
        "value": "--dns01-recursive-nameservers=$RESOLVERS",
    }
]
EOF
)"

    $K rollout status deploy/cert-manager --timeout="$TIMEOUT"
fi

hr 'cloudflare api token secret'
$K create secret generic cloudflare-api-token \
    --from-literal=api-token="$token" \
    --dry-run=client -o yaml | $K apply -f -

hr 'cluster issuers'
sed "s/ACME_EMAIL/$ACME_EMAIL/g" issuers.yaml | $K apply -f -

hr 'done'
$K get clusterissuer
