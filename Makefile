# Directories of charts that depend on an upstream chart.
WRAPPERS := $(patsubst %/Chart.yaml,%,$(shell grep -l '^dependencies:' platform/*/Chart.yaml apps/*/Chart.yaml))

.PHONY: validate test deps test-charts render config

# values.yaml is consistent and every Application renders. No network.
validate:
	helm lint . --quiet
	helm template homelab . --set render.all=true >/dev/null

# The checks themselves work, and templates follow the conventions in
# README.md. No network.
test: validate
	tests/validate_test.sh
	tests/style_test.sh

# Download the upstream charts named in each Chart.yaml and write Chart.lock.
# Versions are pinned exactly, so an existing Chart.lock does not change.
# `build` would need every repository added with `helm repo add` first.
deps:
	@for dir in $(WRAPPERS); do \
		helm dependency update $$dir || exit 1; \
	done

# Every chart in this repository renders with the values its Application
# carries. Needs `make deps`.
test-charts:
	tests/charts_test.sh

# Every Application, managed or not.
render:
	@helm template homelab . --set render.all=true

# Every shared value in resolved form, as KEY=value.
config:
	@helm template homelab . -s templates/config.yaml \
		| yq '.data | to_entries | .[] | .key + "=" + .value'
