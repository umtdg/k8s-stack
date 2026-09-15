#!/usr/bin/env bash

set -euo pipefail

VERSION="${VERSION:-v0.16.1}"
SPEC="${SPEC:-$(dirname "$0")/spec.yaml}"
TIMEOUT="${TIMEOUT:-180s}"

K='kubectl'

hr() { printf '\n--- %s ---\n' "$1"; }

hr 'apply'
$K apply -f \
    "https://raw.githubusercontent.com/metallb/metallb/refs/tags/$VERSION/config/manifests/metallb-native.yaml"

hr 'status'
$K -n metallb-system rollout status deploy/controller --timeout="$TIMEOUT"
$K -n metallb-system rollout status ds/speaker --timeout="$TIMEOUT"

hr 'wait for webhook service endpoints'
for _ in {1..60}; do
    if $K -n metallb-system get endpointslice \
        -l kubernetes.io/service-name=metallb-webhook-service \
        -o jsonpath='{.items[*].endpoints[*].addresses[*]}' 2>/dev/null | grep -q .; then
        break
    fi

    sleep 2
done

$K apply -f "$SPEC"

$K -n metallb-system get ipaddresspool,l2advertisement

