#!/usr/bin/env bash

set -uo pipefail

MANIFEST="${MANIFEST:-test.yaml}"
NS="${NS:-default}"
NAME="${NAME:-lbprobe}"
POOL_START="${POOL_START:-10.10.10.200}"
POOL_END="${POOL_END:-10.10.10.210}"
TIMEOUT="${TIMEOUT:-120s}"

K="kubectl -n $NS"
K_METAL='kubectl -n metallb-system'
rc=0

hr() { printf '\n--- %s ---\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; rc=1; }

ip2int() {
    IFS=. read -r a b c d <<<"$1"
    echo $(((a << 24) + (b << 16) + (c << 8) + d))
}

[[ -f "$MANIFEST" ]] || { printf 'manifest not found: %s\n' "$MANIFEST" >&2; exit 1; }

hr 'metallb health'
$K_METAL get pods -o wide
$K_METAL get ipaddresspool,l2advertisement 2>/dev/null \
    || fail 'no IPAddressPool/L2Advertisement found'

hr 'pre-clean'
$K delete "svc/$NAME" "deploy/$NAME" --ignore-not-found --wait=true

hr 'apply'
$K apply -f "$MANIFEST" || exit 1

hr 'wait for deployment'
$K rollout status "deploy/$NAME" --timeout="$TIMEOUT" \
    || fail 'deployment did not become available'

hr 'wait for EXTERNAL-IP'
if ! $K wait --for=jsonpath='{.status.loadBalancer.ingress[0].ip}' "svc/$NAME" --timeout="$TIMEOUT"; then
    fail 'no EXTERNAL-IP assigned'
    $K_METAL logs deploy/controller --tail=30
fi

LB=$($K get "svc/$NAME" -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

hr 'kubectl get svc'
$K get "svc/$NAME" -o wide

if [[ -n "$LB" ]]; then
    lb_i=$(ip2int "$LB"); s_i=$(ip2int "$POOL_START"); e_i=$(ip2int "$POOL_END")
    if (( lb_i >= s_i && lb_i <= e_i )); then
        printf '\nassigned %s (within %s-%s)\n' "$LB" "$POOL_START" "$POOL_END"
    else
        fail "assigned ${LB} is outside ${POOL_START}-${POOL_END}"
    fi
fi

hr 'which node is announcing the address'
$K_METAL logs ds/speaker --tail=200 2>/dev/null \
	| grep -i "$LB" \
	| tail -5 \
	|| echo "(nothing in speaker logs mentioning $LB yet)"

hr 'curl from this node'
if [[ -n "$LB" ]]; then
    if code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://${LB}/"); then
        printf 'HTTP %s\n' "$code"
        [[ "$code" == "200" ]] || fail "expected HTTP 200, got ${code}"
    else
        fail "curl from node failed (exit $?)"
    fi
fi

hr 'arp entry on this node'
ip neigh show "$LB" 2>/dev/null || echo "(no entry; expected, the VIP is local)"

hr 'result'
if [[ $rc -eq 0 ]]; then
    echo "node-local checks passed"
else
    echo "one or more checks failed"
fi

cat <<EOF

The check that actually matters has to run elsewhere. From a connected
WireGuard client:

    curl -v http://${LB}/
    arp -n ${LB}          # Linux: ip neigh show ${LB}

A reply means the WG VM resolved the VIP by ARP across vmbr0 and MetalLB
answered. If curl from this node succeeded but the client times out, the
fault is WG routing or AllowedIPs, not MetalLB.

EOF

printf 'Press Enter to delete deploy/%s and svc/%s, or Ctrl-C to leave them up. ' \
    "$NAME" "$NAME"
read -r _

hr 'teardown'
$K delete "svc/${NAME}" "deploy/${NAME}" --ignore-not-found --wait=true

exit $rc

