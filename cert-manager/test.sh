#!/usr/bin/env bash

set -uo pipefail

MANIFEST="${MANIFEST:-test.yaml}"
NS="${NS:-cert-manager-test}"
NAME="${NAME:-probe}"
SECRET="${SECRET:-probe-tls}"
DOMAIN="${DOMAIN:-probe.umtdg.com}"
TIMEOUT="${TIMEOUT:-300s}"
RESOLVER="${RESOLVER:-1.1.1.1}"

K="kubectl -n $NS"
rc=0

hr() { printf '\n--- %s ---\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; rc=1; }

[[ -f "$MANIFEST" ]] || { printf 'manifest not found: %s\n' "$MANIFEST" >&2; exit 1; }

hr 'apply'
kubectl apply -f "$MANIFEST" || exit 1

hr "wait for Certificate Ready (DNS-01, timeout $TIMEOUT)"
if ! $K wait --for=condition=Ready "certificate/$NAME" --timeout="$TIMEOUT"; then
    fail 'certifiacte did not become Ready in time'

    hr 'certificate'
    $K describe "certificate/$NAME" | tail -30

    hr 'certificaterequest'
    $K describe certificaterequest 2>/dev/null | tail -30

    hr 'order'
    $K describe order 2>/dev/null | tail -40

    hr 'challenge'
    $K describe challenge 2>/dev/null | tail -40

    hr 'controller logs'
    kubectl -n cert-manager logs deploy/cert-manager --tail=40
fi

hr 'kubectl get certificate'
$K get certificate "$NAME" -o wide

hr 'secret exists with both keys'
if $K get "secret/$SECRET" >/dev/null 2>&1; then
    for key in tls.crt tls.key; do
        if ! $K get "secret/$SECRET" -o jsonpath="{.data.$key}" | grep -q .; then
            fail "secret missing $key"
        fi
    done
else
    fail "secret/$SECRET not found"
fi

crt="$($K get "secret/$SECRET" -o jsonpath='{.data.tls\.crt}' 2>/dev/null | base64 -d)"
if [[ -n "$crt" ]]; then
    hr 'x509 subject / issuer / validity'
    echo "$crt" | openssl x509 -noout -subject -issuer -dates

    hr 'subject alternative names'
    sans=$(echo "$crt" | openssl x509 -noout -ext subjectAltName)
    printf '%s\n' "$sans"
    grep -q "DNS:$DOMAIN" <<<"$sans" | fail "SAN missing $DOMAIN"
    grep -q "DNS:\*\.$DOMAIN" <<<"$sans" | fail "SAN missing *.$DOMAIN"

    hr 'issued by staging CA'
    issuer=$(echo "$crt" | openssl x509 -noout -issuer)
    if grep -q 'STAGING' <<<"$issuer"; then
        echo "ok: $issuer"
    else
        fail "issuer does not look like staging: $issuer"
    fi

    hr 'not expired'
    if echo "$crt" | openssl x509 -noout -checkend 0; then
        echo 'ok: currently valid'
    else
        fail 'certificate is already expired'
    fi

    hr 'key matches certificate'
    key=$($K get "secret/$SECRET" -o jsonpath='{.data.tls\.key}' | base64 -d)
    cmod=$(echo "$crt" | openssl x509 -noout -modulus 2>/dev/null | openssl md5)
    kmod=$(echo "$key" | openssl rsa -noout -modulus 2>/dev/null | openssl md5)
    if [[ -n "$cmod" && "$cmod" == "$kmod" ]]; then
        echo "ok: $cmod"
    else
        echo "cert:$cmod key:$kmod"
        [[ -n "$cmod" ]] && fail 'key does not match certificate'
    fi
else
    fail 'no certificate to inspect. skipping x509 checks'
fi

hr 'challenge records cleaned up'
left=$(dig +short TXT "_acme-challenge.$DOMAIN" "@$RESOLVER")
if [[ -z "$left" ]]; then
    echo 'ok: no_acme-challenge TXT remaining'
else
    printf '%s\n' "$left"
    fail 'stale _acme-challenge TXT left in the zone'
fi

hr 'no orphaned challenge objects'
if [[ -z "$($K get challenge -o name 2>/dev/null)" ]]; then
    echo 'ok: no Challenge resources'
else
    $K get challenge
    fail 'Challenge resource still present'
fi

hr 'result'
if [[ $rc -eq 0 ]]; then
    echo 'all checks passed'
else
    fail 'one or more checks failed'
fi

printf '\nPress Enter to delete namespace %s, or Ctrl-C to leave it untouched' "$NS"
read -r _

hr 'teardown'
kubectl delete ns "$NS" --ignore-not-found --wait=true
