#!/usr/bin/env bash

set -uo pipefail

MANIFEST="${MANIFEST:-test.yaml}"
NS="${NS:-cnpg}"
NAME="${NAME:-pgprobe}"
CLUSTER="${CLUSTER:-pg}"
DATA_DIR="${DATA_DIR:-/mnt/data/local-path}"
TIMEOUT="${TIMEOUT:-180s}"

K="kubectl -n $NS"
rc=0

hr() { printf '\n--- %s ---\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; rc=1; }

[[ -f "$MANIFEST" ]] || { fail "manifest not found: $MANIFEST"; exit 1; }

hr 'cluster status'
$K get "cluster/$CLUSTER" -o wide || fail "cluster/$CLUSTER not found"

phase=$($K get "cluster/$CLUSTER" -o jsonpath='{.status.phase}' 2>/dev/null)
phase="${phase:-<none>}"
printf 'phase: %s\n' "$phase"
[[ "$phase" == 'Cluster in healthy state' ]] || fail "unexpected phase: $phase"

ready=$($K get "cluster/$CLUSTER" -o jsonpath='{.status.readyInstances}' 2>/dev/null)
[[ "$ready" == '1' ]] || fail "readyInstances is '${ready:-<none>}', expected 1"

hr 'image in use'
$K get "cluster/$CLUSTER" -o jsonpath='{.status.image}{"\n"}'

hr 'services'
$K get svc -o wide
for svc in "$CLUSTER-rw" "$CLUSTER-ro" "$CLUSTER-r"; do
    svc="svc/$svc"
    $K get "$svc" >/dev/null 2>&1 || fail "missing $svc"
done

hr 'databases'
$K get database -o wide
for db in portfolio gitea; do
    applied=$($K get "database/$db" -o jsonpath='{.status.applied}' 2>/dev/null)
    [[ "$applied" == 'true' ]] || fail "database/$db not applied (status.applied=${applied:-<none>})"
done

hr 'pvc bound and backed by local-path'
$K get pvc -o wide
bound=$( \
    $K get "pvc/$CLUSTER-1" -o jsonpath='{.status.phase}' 2>/dev/null \
)
[[ "$bound" == 'Bound' ]] || fail "pvc/$CLUSTER-1 phase is '${bound:-<none>}'"

sc=$( \
    $K get "pvc/$CLUSTER-1" -o jsonpath='{.spec.storageClassName}' 2>/dev/null \
)
[[ "$sc" == 'local-path' ]] || fail "pvc storageClass is '${sc:-<none>}', expected 'local-path'"

if [[ -d "$DATA_DIR" ]]; then
    hr "host directory: $DATA_DIR"
    find "$DATA_DIR" -mindepth 1 -maxdepth 1 -type d -name "pvc-*_${NS}_${CLUSTER}-1" \
        | head -1 | grep -q . \
        || fail "no pvc-*_${NS}_${CLUSTER}-1 directory under $DATA_DIR"
    ls -ln "$DATA_DIR"
fi

hr 'pre-clean'
$K delete "pod/$NAME" --ignore-not-found --wait=true

hr 'apply probe'
$K apply -f "$MANIFEST" || exit 1

hr 'wait for probe ready'
if ! $K wait --for=condition=Ready "pod/$NAME" --timeout="$TIMEOUT"; then
    fail 'probe pod did not become Ready in time'
    $K describe "pod/$NAME" | tail -30
fi

hr 'connect as the application role'
if out=$($K exec "$NAME" -- psql -At -c 'select current_user, current_database()' 2>&1); then
    printf '%s\n' "$out"
    [[ "$out" == 'portfolio|portfolio' ]] || fail "unexpected identity: $out"
else
    printf '%s\n' "$out" >&2
    fail 'could not connect to pg-rw as portfolio'
fi

hr 'write, read back, drop'
sql='create table if not exists probe(v text); truncate probe; insert into probe values ($$ok$$); select -v from probe; drop table probe;'
if out=$($K exec "$NAME" -- psql -At -c "$sql" 2>&1); then
    printf '%s\n' "$out"
    grep -qx 'ok' <<<"$out" || fail "did not read back the written row"
else
    printf '%s\n' "$out" >&2
    fail 'DDL/DML as the application role failed'
fi

hr 'role owns its database'
sql="select pg_catalog.pg_get_userbyid(datdba) from pg_database where datname='portfolio'"
owner=$($K exec "$NAME" -- psql -At -c "$sql" 2>/dev/null)
owner="${owner:-<none>}"
printf 'owner: %s\n' "$owner"
[[ "$owner" == 'portfolio' ]] || fail "portfolio is owned by '$owner'"

hr 'writes reach the primary through pg-rw'
sql='select pg_is_in_recovery()'
ro=$($K exec "$NAME" -- psql -At -c "$sql" 2>/dev/null)
[[ "$ro" == 'f' ]] || fail "pg-rw resolved to a standby (pg_is_in_recovery=${ro:-<none>})"

hr 'cross-database isolation (informational)'
cat <<'EOF'

Postgres grants CONNECT on every database to PUBLIC by default, so the portfolio
role can open a connection to the gitea database and vica versa. Neither can
read the other's tables. If that is not good enough:

    revoke connect on database gitea from public;
    grant connect on database gitea to gitea;
EOF

hr 'result'
if [[ $rc -eq 0 ]]; then
    echo 'all checks passed'
else
    echo 'one or more checks failed'
fi

printf '\nPress Enter to delete pod/%s, or Ctrl-C to leave it untouched' "$NAME"
read -r _

hr 'teardown'
$K delete "pod/$NAME" --ignore-not-found --wait=true

exit $rc
