#!/usr/bin/env bash
#
# Proves that values.schema.json and templates/_validate.tpl reject what they
# claim to reject, and that the committed values.yaml passes. Needs helm only;
# nothing is downloaded.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
rc=0

render() { helm template homelab "$ROOT" "$@" 2>&1; }

# expect_fail <description> <text the error must contain> <helm args...>
# For what templates/_validate.tpl checks: how values relate.
expect_fail() {
    local what=$1 want=$2 out
    shift 2

    if out=$(render "$@"); then
        printf 'FAIL: %s: rendered, expected an error\n' "$what" >&2
        rc=1
    elif ! grep -qF -- "$want" <<<"$out"; then
        printf 'FAIL: %s: failed, but not with "%s":\n%s\n' "$what" "$want" "$out" >&2
        rc=1
    else
        printf 'OK: %s\n' "$what"
    fi
}

# expect_schema_fail <description> <key the error must name> <helm args...>
# For what values.schema.json checks: what one value must look like. The
# wording of these errors is Helm's and differs between versions; the key is
# in all of them.
expect_schema_fail() {
    local what=$1 key=$2 out
    shift 2

    if out=$(render "$@"); then
        printf 'FAIL: %s: rendered, expected an error\n' "$what" >&2
        rc=1
    elif ! grep -q 'schema' <<<"$out" || ! grep -qF -- "$key" <<<"$out"; then
        printf 'FAIL: %s: failed, but not as a schema error naming "%s":\n%s\n' "$what" "$key" "$out" >&2
        rc=1
    else
        printf 'OK: %s\n' "$what"
    fi
}

if out=$(render --set render.all=true); then
    printf 'OK: values.yaml renders\n'
else
    printf 'FAIL: values.yaml does not render:\n%s\n' "$out" >&2
    rc=1
fi

# ---- values.schema.json: one value at a time --------------------------------

expect_schema_fail 'missing required value' 'domain' \
    --set domain=null
expect_schema_fail 'unknown top-level key' 'domian' \
    --set domian=example.org
expect_schema_fail 'malformed address' 'ingressVIP' \
    --set network.ingressVIP=192.0.2.300
expect_schema_fail 'host with two labels' 'host' \
    --set services.gitea.host=git.internal
expect_schema_fail 'relative host path' 'hostPath' \
    --set storage.hostPath=mnt/data
expect_schema_fail 'directory outside the repository' 'dir' \
    --set services.pfo.dir=../elsewhere
expect_schema_fail 'service without a namespace' 'namespace' \
    --set services.pfo.namespace=null
expect_schema_fail 'unknown argo key' 'autoSync' \
    --set services.pfo.argo.autoSync=true
expect_schema_fail 'missing required service' 'argocd' \
    --set services.argocd=null
expect_schema_fail 'service named root' 'root' \
    --set services.root.dir=apps/pfo --set services.root.wave=0 --set services.root.namespace=x

# ---- templates/_validate.tpl: how values relate -----------------------------

# A network of its own (TEST-NET-1), so these cases do not depend on the
# addresses in values.yaml. Each case then breaks one thing.
net=(
    --set network.nodeIP=192.0.2.2
    --set network.ingressVIP=192.0.2.10
    --set network.pool.start=192.0.2.10
    --set network.pool.end=192.0.2.20
)

if out=$(render "${net[@]}"); then
    printf 'OK: the test network renders\n'
else
    printf 'FAIL: the test network does not render:\n%s\n' "$out" >&2
    rc=1
fi

expect_fail 'VIP outside the pool' 'is outside the MetalLB pool' \
    "${net[@]}" --set network.ingressVIP=192.0.2.50
expect_fail 'node address inside the pool' 'is inside the MetalLB pool' \
    "${net[@]}" --set network.nodeIP=192.0.2.15
expect_fail 'pool start after end' 'is after network.pool.end' \
    "${net[@]}" --set network.pool.start=192.0.2.30
expect_fail 'host used twice' 'is already used by' \
    --set services.gitea.host=pfo
expect_fail 'directory used twice' 'is already used by' \
    --set services.pfo.dir=apps/gitea
expect_fail 'directory without a chart' 'Chart.yaml not found' \
    --set services.pfo.dir=apps/nothing-here
expect_fail 'external chart and a local chart' 'a service has one chart' \
    --set services.pfo.git.repo=https://example.invalid/x.git \
    --set services.pfo.git.path=chart --set services.pfo.git.ref=v1.0.0
expect_fail 'floating git ref' 'is not a pinned tag or commit' \
    --set services.local-path.git.ref=master
expect_fail 'secret of an unknown service' 'is not a service' \
    --set secrets.argoRepo.service=ghost

# --set replaces a whole list, so these cases spell out complete databases.
database=(
    --set 'postgres.databases[0].name=probe'
    --set 'postgres.databases[0].secret=probe-db-creds'
    --set 'postgres.databases[0].consumer.service=pfo'
    --set 'postgres.databases[0].consumer.secret=probe-db'
)
second=(
    --set 'postgres.databases[1].name=other'
    --set 'postgres.databases[1].secret=other-db-creds'
    --set 'postgres.databases[1].consumer.service=gitea'
    --set 'postgres.databases[1].consumer.secret=other-db'
)

if out=$(render "${database[@]}" "${second[@]}"); then
    printf 'OK: the test databases render\n'
else
    printf 'FAIL: the test databases do not render:\n%s\n' "$out" >&2
    rc=1
fi

expect_schema_fail 'database name that is not an identifier' 'name' \
    "${database[@]}" --set 'postgres.databases[0].name=my-db'
expect_schema_fail 'database without a secret' 'secret' \
    "${database[@]}" --set 'postgres.databases[0].secret=null'
expect_fail 'database consumed by an unknown service' 'is not a service' \
    "${database[@]}" --set 'postgres.databases[0].consumer.service=ghost'
expect_fail 'database name used twice' 'is used twice' \
    "${database[@]}" "${second[@]}" --set 'postgres.databases[1].name=probe'
expect_fail 'two databases for one service' 'already consumes another database' \
    "${database[@]}" "${second[@]}" --set 'postgres.databases[1].consumer.service=pfo'

# A dependency version that is a range, in a copy of the repository.
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
tar -C "$ROOT" --exclude=.git --exclude=charts -cf - . | tar -C "$tmp" -xf -
sed -i 's/^    version: .*/    version: ^1.0.0/' "$tmp/platform/metallb/Chart.yaml"
if out=$(helm template homelab "$tmp" 2>&1); then
    printf 'FAIL: a version range in Chart.yaml rendered, expected an error\n' >&2
    rc=1
elif ! grep -qF 'pin one exact version' <<<"$out"; then
    printf 'FAIL: a version range in Chart.yaml failed with something else:\n%s\n' "$out" >&2
    rc=1
else
    printf 'OK: dependency version that is a range\n'
fi

# A service switched off by default renders no Application; switched on, it does.
count() { render "$@" | grep -c '^kind: Application$'; }
if [[ "$(count)" == 1 && "$(count --set services.pfo.argo.managed=true)" == 2 ]]; then
    printf 'OK: argo.managed controls whether an Application exists\n'
else
    printf 'FAIL: argo.managed does not control Application rendering\n' >&2
    rc=1
fi

# `false` in a service must win over `true` in argoDefaults.
prune=$(
    render --set services.metallb.argo.managed=true --set services.metallb.argo.automated=true \
        -s templates/applications.yaml | grep -m1 'prune:' | tr -d ' '
)
if [[ "$prune" == 'prune:false' ]]; then
    printf 'OK: a service can turn pruning off\n'
else
    printf 'FAIL: metallb prune is "%s", expected "prune:false"\n' "$prune" >&2
    rc=1
fi

exit $rc
