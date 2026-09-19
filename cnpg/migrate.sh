#!/usr/bin/env bash

set -euo pipefail

OLD_NS="${OLD_NS:-default}"
OLD_DEPLOY="${OLD_DEPLOY:-postgres}"
OLD_DB="${OLD_DB:-portfolio}"
OLD_USER="${OLD_USER:-postgres}"

NS="${NS:-cnpg}"
CLUSTER="${CLUSTER:-pg}"
NEW_DB="${NEW_DB:-portfolio}"
NEW_OWNER="${NEW_OWNER:-portfolio}"

DUMP="${DUMP:-$OLD_DB-$(date +%F-%H%M).sql}"

hr() { printf '\n--- %s ---\n' "$1"; }

OLD_K="kubectl -n $OLD_NS"
NEW_K="kubectl -n $NS"

# Exact row counts per table. n_live_tup is only an ANALYZE estimate and will
# not prove that nothing was lost.
COUNTS="
select relname,
       (xpath('/row/c/text()',
              query_to_xml(format('select count(*) as c from %I.%I',
                                  schemaname, relname),
                           false, true, '')))[1]::text::bigint as rows
from pg_stat_user_tables
order by relname
"

hr 'source is running'
$OLD_K rollout status "deploy/$OLD_DEPLOY" --timeout=60s

hr 'source version'
$OLD_K exec "deploy/$OLD_DEPLOY" -- \
    psql -U "$OLD_USER" -At -c 'select version()'

hr 'target version'
$NEW_K exec "$CLUSTER-1" -- \
    psql -U postgres -At -c 'select version()'

hr "source database: $OLD_DB"
$OLD_K exec "deploy/$OLD_DEPLOY" -- psql -U "$OLD_USER" -c '\l'

n=$( \
    $OLD_K exec "deploy/$OLD_DEPLOY" -- \
        psql -U "$OLD_USER" -d "$OLD_DB" -At -c \
        "select count(*) from pg_tables where schemaname='public'" \
)
printf 'public tables in source: %s\n' "$n"

if [[ "$n" == '0' ]]; then
    printf 'source %s has no tables, wrong OLD_DB?\n' "$OLD_DB" >&2
    exit 1
fi

hr "dump to $DUMP"
$OLD_K exec "deploy/$OLD_DEPLOY" -- \
    pg_dump -U "$OLD_USER" -d "$OLD_DB" --no-owner --no-acl > "$DUMP"

ls -lh "$DUMP"
grep -q 'PostgreSQL database dump complete' "$DUMP" \
    || { echo 'dump looks truncated, aborting' >&2; exit 1; }

hr 'target is empty'
n=$( \
    $NEW_K exec "$CLUSTER-1" -- \
        psql -U postgres -d "$NEW_DB" -At -c \
        "select count(*) from pg_tables where schemaname='public'" \
)
printf 'public tables in target: %s\n' "$n"

if [[ "$n" != '0' ]]; then
    printf 'refusing non-empty target %s\n' "$NEW_DB" >&2
    exit 1
fi

hr "restore as $NEW_OWNER"
# PGOPTIONS sets the role at session start, so every object the dump creates is
# owned by $NEW_OWNER on creation. No REASSIGN OWNED afterwards: that command
# also covers shared objects (databases, tablespaces), so running it as
# postgres would try to hand template0, template1 and postgres to $NEW_OWNER.
#
# Anything in the dump needing superuser (CREATE EXTENSION, most COMMENT ON)
# will now fail rather than silently succeed. ON_ERROR_STOP surfaces it.
$NEW_K exec -i "$CLUSTER-1" -- \
    env PGOPTIONS="-c role=$NEW_OWNER" \
    psql -U postgres -d "$NEW_DB" -v ON_ERROR_STOP=1 < "$DUMP"

hr 'ownership of restored tables'
$NEW_K exec "$CLUSTER-1" -- psql -U postgres -d "$NEW_DB" -c \
    "select tablename, tableowner from pg_tables
     where schemaname='public' order by tablename"

hr 'row counts, source vs target'
printf '\nsource:\n'
$OLD_K exec "deploy/$OLD_DEPLOY" -- \
    psql -U "$OLD_USER" -d "$OLD_DB" -c "$COUNTS"

printf '\ntarget:\n'
$NEW_K exec "$CLUSTER-1" -- \
    psql -U postgres -d "$NEW_DB" -c "$COUNTS"

cat <<EOF

Compare the two tables above. If they match:

    1. point pfo at the new cluster: update SPRING_DATASOURCE_URL in the
    pfo ConfigMap, apply it, then
        kubectl rollout restart deploy/pfo
    2. confirm the application works
    3. only then remove the old instance
        kubectl -n $OLD_NS delete deploy/$OLD_DEPLOY svc/$OLD_DEPLOY

Keep $DUMP until step 3 is done.

EOF
