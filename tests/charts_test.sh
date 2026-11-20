#!/usr/bin/env bash
#
# Renders every chart in this repository with the values its Application
# carries. Needs helm, yq (mikefarah, v4) and the upstream charts: run
# `make deps` first.

set -uo pipefail

yq --version | grep -q mikefarah || { echo 'charts_test.sh needs mikefarah yq' >&2; exit 1; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
rc=0

apps=$(helm template homelab "$ROOT" -s templates/applications.yaml) || exit 1
repo=$(yq '.repo.url' "$ROOT/values.yaml")

for name in $(yq -N 'select(.spec.source.repoURL == "'"$repo"'") | .metadata.name' <<<"$apps"); do
    app=$(yq 'select(.metadata.name == "'"$name"'")' <<<"$apps")
    path=$(yq '.spec.source.path' <<<"$app")
    release=$(yq '.spec.source.helm.releaseName' <<<"$app")
    namespace=$(yq '.spec.destination.namespace' <<<"$app")

    if [[ "$(yq '.dependencies | length' "$ROOT/$path/Chart.yaml")" != 0 && ! -d "$ROOT/$path/charts" ]]; then
        printf 'FAIL: %s: upstream chart not downloaded, run "make deps"\n' "$name" >&2
        rc=1
        continue
    fi

    if out=$(
        yq '.spec.source.helm.valuesObject // {}' <<<"$app" \
            | helm template "$release" "$ROOT/$path" -n "$namespace" --include-crds -f - 2>&1
    ) && [[ -n "$out" ]]; then
        printf 'OK: %s renders %d objects (%s)\n' "$name" "$(grep -c '^kind:' <<<"$out")" "$path"
    else
        printf 'FAIL: %s does not render:\n%s\n' "$name" "$out" >&2
        rc=1
    fi
done

exit $rc
