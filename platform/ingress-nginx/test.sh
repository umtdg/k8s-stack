#!/usr/bin/env bash

set -uo pipefail

MANIFEST="${MANIFEST:-test.yaml}"
NS="${NS:-ingress-test}"
TIMEOUT="${TIMEOUT:-2m}"
VIP="${VIP:-10.10.10.200}"
HOST="${HOST:-echo.umtdg.com}"

hr() { printf '\n--- %s ---\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; rc=1; }

function cleanup() {
    hr 'cleanup'
    kubectl delete -f "$MANIFEST" --ignore-not-found --wait=true
}
trap cleanup EXIT

K="kubectl -n $NS"

hr 'apply'
$K apply -f "$MANIFEST"
$K rollout status deploy/echo --timeout="$TIMEOUT"

hr 'curl 30 times with 2s intervals'
declare i code
for i in {1..30}; do
    code=$( \
        curl -sk -o /dev/null -w '%{http_code}' \
        --resolve "$HOST:443:$VIP" "https://$HOST/" || true \
    )

    [[ "$code" == '200' ]] && break
    sleep 2
done

[[ "$code" == 200 ]] || { fail "https://$HOST returnes '$code'"; exit "$rc"; }
echo "routing ok: $HOST -> $VIP -> echo"

hr 'fallback vhost must 404'
code=$(curl -sk -o /dev/null -w '%{http_code}' "https://$VIP/" || true)
[[ "$code" == '404' ]] || { fail "default backend returned '$code', expected '404'"; exit "$rc"; }
echo 'default backend ok'

hr 'cert identity'
declare subject
subject=$( \
    echo \
    | openssl s_client -connect "$VIP:443" -servername "$HOST" 2>/dev/null \
    | openssl x509 -noout -subject 2>/dev/null || true
)
printf 'serving cert: %s\n' "${subject:-<none>}"

