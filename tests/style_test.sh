#!/usr/bin/env bash
#
# Checks the template conventions in README.md that a machine can check.
# Needs nothing but grep and awk.

set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
rc=0

shopt -s nullglob
manifests=(templates/*.yaml platform/*/templates/*.yaml apps/*/templates/*.yaml)
values=(platform/*/values.tpl.yaml apps/*/values.tpl.yaml)
helpers=(templates/_*.tpl platform/*/templates/_*.tpl apps/*/templates/_*.tpl)

# rule <description> <grep output, empty when the rule holds>
rule() {
    if [[ -z "$2" ]]; then
        printf 'OK: %s\n' "$1"
    else
        printf 'FAIL: %s\n%s\n' "$1" "$2" >&2
        rc=1
    fi
}

rule 'no right-trimmed actions outside helpers' \
    "$(grep -n -- '-}}' "${manifests[@]}" "${values[@]}")"

rule 'no YAML comments in manifest templates' \
    "$(grep -n '^[[:space:]]*#' "${manifests[@]}")"

rule 'toYaml takes its value as an argument' \
    "$(grep -n '|[[:space:]]*toYaml' "${manifests[@]}" "${values[@]}" "${helpers[@]}")"

rule 'nindent equals the indentation of the line it is on' \
    "$(awk '
        match($0, /nindent [0-9]+/) {
            n = substr($0, RSTART + 8, RLENGTH - 8) + 0
            indent = match($0, /[^ ]/) - 1
            if (indent != n) printf "%s:%d: indented %d, nindent %d\n", FILENAME, FNR, indent, n
        }
    ' "${manifests[@]}" "${values[@]}")"

rule 'an include that inserts a block is on its own line' \
    "$(grep -n 'nindent' "${manifests[@]}" "${values[@]}" | grep -v ':[[:space:]]*{{- .* | nindent [0-9]* }}$')"

rule 'define trims on both sides' \
    "$(grep -n '{{-\? *define ' "${helpers[@]}" | grep -v ':{{- define "[A-Za-z0-9.-]*" -}}$')"

# The root chart's helper files are logic: one action per line, trimmed on
# both sides, nested two spaces per level.
logic=(templates/_*.tpl)
rule 'logic helpers trim every action on both sides' \
    "$(grep -n '^[[:space:]]*{{-\{0,1\} ' "${logic[@]}" | grep -v ':[[:space:]]*{{- .* -}}$')"

rule 'logic helpers indent by two spaces' \
    "$(awk '/^ +{{/ { n = match($0, /[^ ]/) - 1; if (n % 2) printf "%s:%d: indented %d\n", FILENAME, FNR, n }' "${logic[@]}")"

# A helper is named after the chart it belongs to.
misnamed=''
for file in "${helpers[@]}"; do
    chart=$(awk '$1 == "name:" { print $2; exit }' "$(dirname "$(dirname "$file")")/Chart.yaml")
    misnamed+=$(grep -n '{{- define "' "$file" | grep -v "define \"$chart\\." | sed "s|^|$file:|")
done
rule 'helpers are named <chart>.<what they return>' "$misnamed"

rule 'no tabs or trailing whitespace' \
    "$(grep -n -P '\t|[ \t]+$' "${manifests[@]}" "${values[@]}" "${helpers[@]}" values.yaml)"

exit $rc
