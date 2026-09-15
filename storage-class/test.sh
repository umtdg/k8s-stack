#!/usr/bin/env bash

set -uo pipefail

MANIFEST="${MANIFEST:-test.yaml}"
NS="${NS:-default}"
NAME="${NAME:-probe}"
DATA_DIR="${DATA_DIR:-/mnt/data/local-path}"
TIMEOUT="${TIMEOUT:-120s}"

K="kubectl -n ${NS}"
rc=0

hr() { printf '\n--- %s ---\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; rc=1; }

[[ -f "$MANIFEST" ]] || { printf 'manifest not found: %s\n' "$MANIFEST" >&2; exit 1; }

hr 'apply'
$K apply -f "$MANIFEST" || exit 1

hr 'wait for pod Ready'
if ! $K wait --for=condition=Ready "pod/$NAME" --timeout="$TIMEOUT"; then
    fail "pod did not become Ready"
    $K describe "pod/$NAME" | tail -30
fi

hr 'wait for PVC Bound'
if ! $K wait --for=jsonpath='{.status.phase}'=Bound "pvc/$NAME" --timeout="$TIMEOUT"; then
    fail "PVC did not bind"
    $K describe "pvc/$NAME" | tail -30
fi

hr 'kubectl get pvc'
$K get pvc "$NAME" -o wide

hr 'kubectl get pv'
$K get pv -o wide | grep -E "NAME|$NS/$NAME" || fail "no PV for $NS/$NAME"

hr 'kubectl get pod'
$K get pod "$NAME" -o wide

hr 'read file written by the pod'
if out=$($K exec "$NAME" -- cat /data/probe.txt 2>&1); then
    printf '%s\n' "$out"
    [[ "$out" == 'ok' ]] || fail "unexpected file contents: $out"
else
    printf '%s\n' "$out" >&2
    fail 'exec failed'
fi

hr "host directory: $DATA_DIR"
if [[ -d "$DATA_DIR" ]]; then
    ls -ln "$DATA_DIR"
    sub=$(find "$DATA_DIR" -mindepth 1 -maxdepth 1 -type d -name "pvc-*_${NS}_$NAME" | head -1)
    if [[ -n "$sub" ]]; then
        printf '\ncontents of %s:\n' "$sub"
        ls -ln "$sub"

        mode=$(stat -c '%a %u %g' "$sub")
        printf '\nmode uid gid: %s (expect 777 0 0)\n' "$mode"
        [[ "$mode" == '777 0 0' ]] || fail "unexpected mode/ownership: ${mode}"
    else
        fail "no pvc-*_${NS}_$NAME directory under $DATA_DIR"
    fi
else
    fail "$DATA_DIR does not exist or is not a directory"
fi

hr 'result'
if [[ $rc -eq 0 ]]; then
    echo 'all checks passed'
else
    echo 'one or more checks failed'
fi

printf '\nPress Enter to delete pod/%s and pvc/%s, or Ctrl-C to leave them untouched' "$NAME" "$NAME"
read -r _

hr 'teardown'
$K delete "pod/$NAME" --ignore-not-found --wait=true
$K delete "pvc/$NAME" --ignore-not-found --wait=true

if [[ -d "$DATA_DIR" ]]; then
    hr "$DATA_DIR after teardown (should be empty: reclaimPolicy is Delete)"
    ls -ln "$DATA_DIR"
fi

