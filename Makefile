WRAPPERS := $(patsubst %/Chart.yaml,%,$(shell grep -l '^dependencies:' platform/*/Chart.yaml apps/*/Chart.yaml))

.PHONY: bootstrap deps test

bootstrap: deps
	helm template homelab . -s templates/argocd.yaml \
		| yq '.spec.source.helm.valuesObject' \
		| helm upgrade --install argocd platform/argocd -n argocd --create-namespace \
			-f - --wait --timeout 10m
	helm template homelab . -s templates/root.yaml | kubectl apply -f -

deps:
	@for dir in $(WRAPPERS); do \
		helm dependency update $$dir || exit 1; \
	done

test:
	helm template homelab . >/dev/null
	tests/charts_test.sh
