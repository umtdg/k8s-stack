#!/usr/bin/env bash

set -uo pipefail

MANIFEST="${MANIFEST:-test.yaml}"
NS="${NS:-argocd}"
RELEASE="${RELEASE:-argocd}"
APP="${APP:-argocd-probe}"
APP_NS="${APP_NS:-argocd-test}"
HOST="${HOST:-argo.umtdg.com}"
VIP="${VIP:-10.10.10.200}"
TIMEOUT="${TIMEOUT:-180s}"
SYNC_TIMEOUT="${SYNC_TIMEOUT:-300s}"
DELETE_TIMEOUT="${DELETE_TIMEOUT:-120s}"
CRD_TIMEOUT="${CRD_TIMEOUT:-30s}"
GUESTBOOK_UI_TIMEOUT="${GUESTBOOK_UI_TIMEOUT:-90s}"
KEEP="${KEEP:-0}"

K="kubectl -n $NS"
K_APP="kubectl -n $APP_NS"
rc=0

hr() { printf '\n--- %s ---\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; rc=1; }
ok() { printf 'OK: %s\n' "$1"; }

curl_api() { curl -sk --resolve "$HOST:443:$VIP" "$@"; }

json_escape() {
    local s=$1
    s=${s//\\/\\\\} # escape backslash first, or the next line doubles its own output
    s=${s//\"/\\\"} # escape double quote
    printf '%s' "$s"
}

remove_finalizers() {
    $K patch "application/$APP" --type=merge \
        -p '{"metadata":{"finalizers":null}}' >/dev/null 2>&1
    $K delete "application/$APP" --ignore-not-found "$@"
}

cleanup() {
    hr 'cleanup'
    if [[ "$KEEP" == '1' ]]; then
        printf '\nKeeping %s in place since KEEP=1\n' "$APP"
        return
    fi

    if [[ ! -f "$MANIFEST" ]]; then
        printf '\nSkipping cleanup without a manifest file\n'
        return
    fi

    if ! kubectl delete -f "$MANIFEST" --ignore-not-found --wait=true --timeout="$DELETE_TIMEOUT"; then
        printf 'delete timed out, removing finalizer\n' >&2
        remove_finalizers --wait=false
    fi

    kubectl delete ns "$APP_NS" --ignore-not-found --wait=false
}
trap cleanup EXIT

debug_application() {
    hr 'debug: application'
    $K get "application/$APP" -o wide 2>/dev/null
    $K get "application/$APP" -o jsonpath='
conditions: {.status.conditions}
operation:  {.status.operationState.phase} {.status.operationState.message}
' 2>/dev/null

    hr 'debug: resource tree'
    $K get "application/$APP" \
        -o jsonpath='{range .status.resources[*]}{.kind}/{.name} {.status} {.health.status}{"\n"}{end}' \
        2>/dev/null

    hr 'debug: repo-server'
    $K logs "deploy/$RELEASE-repo-server" --tail=40

    hr 'debug: application-controller'
    $K logs "sts/$RELEASE-application-controller" --tail=40
}

[[ -f "$MANIFEST" ]] || { fail "manifest not found: $MANIFEST"; exit 1; }

hr 'helm release'
helm -n "$NS" status "$RELEASE" >/dev/null 2>&1 || fail 'helm release not found'

hr 'workloads'
$K get pods -o wide
if ! $K wait --for=condition=Ready pod \
    -l "app.kubernetes.io/part-of=argocd" --timeout="$TIMEOUT"; then
    fail 'not all argocd pods are Ready'
    $K get pods
    $K describe pods -l 'app.kubernetes.io/part-of=argocd' \
        | grep -A5 -i 'events:' | tail -40
fi

hr 'crds established'
for crd in applications.argoproj.io applicationsets.argoproj.io appprojects.argoproj.io; do
    if kubectl wait --for=condition=Established "crd/$crd" \
        --timeout="$CRD_TIMEOUT" >/dev/null 2>&1; then
        ok "$crd"
    else
        fail "$crd not Established"
    fi
done

hr 'server runs insecure (no TLS behind nginx)'
insecure=$( \
    $K get cm argocd-cmd-params-cm -o jsonpath='{.data.server\.insecure}' \
    2>/dev/null \
)
if [[ "$insecure" == 'true' ]]; then
    ok 'server.insecure=true'
else
    fail "server.insecure is '${insecure:-<unset>}'. nginx will loop on redirects"
fi

hr 'ingress'
K_INGRESS="$K get ingress/$RELEASE-server"
$K_INGRESS -o wide 2>/dev/null || fail "ingress/$RELEASE-server is missing"

ingress_host=$($K_INGRESS -o jsonpath='{.spec.rules[0].host}' 2>/dev/null)
if [[ "$ingress_host" != "$HOST" ]]; then
    fail "ingress host is '${ingress_host:-<none>}', expected '$HOST'"
fi

ingress_class=$($K_INGRESS -o jsonpath='{.spec.ingressClassName}' 2>/dev/null)
if [[ "$ingress_class" != 'nginx' ]]; then
    fail "ingress class is '${ingress_class:-<none>}', expected 'nginx'"
fi

ingress_vip=$($K_INGRESS -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
if [[ "$ingress_vip" != "$VIP" ]]; then
    fail "ingress VIP is '${ingress_vip:-<none>}', expected '$VIP'"
fi

hr "https://$HOST through VIP"
url="https://$HOST/"
code=''
for _ in {1..15}; do
    code=$(curl_api -o /dev/null -w '%{http_code}' --max-time 5 "$url" || true)
    [[ "$code" == '200' ]] && break
    sleep 2
done

[[ "$code" == '200' ]] || fail "expected HTTP 200, got '${code:-<none>}'"

redirects=$(curl_api -o /dev/null -w '%{num_redirects}' -L --max-time 10 "$url" || echo '?')
if [[ "$redirects" == '0' ]]; then
    ok 'no redirect chain'
else
    fail "server redirected $redirects times; check server.insecure"
fi

hr 'serving certificate'
subject=$(
    echo | openssl s_client -connect "$VIP:443" -servername "$HOST" 2>/dev/null \
        | openssl x509 -noout -subject -issuer -dates 2>/dev/null
)
printf '%s\n' "${subject:-<none>}"
if grep -qi "Let's Encrypt\|ISRG\|STAGING" <<<"$subject"; then
    ok 'wildcard from cert-manager is being served'
else
    fail 'nginx fell back to its self-signed default instead of the cert-manager wildcard'
fi

hr 'api session'
pw="${ARGOCD_PASSWORD:-}"
if [[ -z "$pw" ]]; then
    pw=$(
        $K get secret argocd-initial-admin-secret \
            -o jsonpath='{.data.password}' 2>/dev/null \
        | base64 -d
    )
fi

token=''
if [[ -n "$pw" ]]; then
    body=$(printf '{"username":"admin","password":"%s"}' "$(json_escape "$pw")")
    token=$(
        curl_api -X POST -H 'Content-Type: application/json' \
            -d "$body" "https://$HOST/api/v1/session" 2>/dev/null \
        | grep -o '"token":"[^"]*"' | cut -d '"' -f4
    )

    if [[ -n "$token" ]]; then
        ok 'admin login returned a token'
    else
        fail 'admin login failed'
    fi
else
    echo 'no password available (initial secret deleted and ARGOCD_PASSWORD is unset)'
    echo 'skipping api check'
fi

hr 'configured repositories'
if [[ -z "$token" ]]; then
    echo 'skipping, admin token is empty'
else
    repos=$(
        curl_api -H "Authorization: Bearer $token" \
            "https://$HOST/api/v1/repositories" 2>/dev/null
    )

    if grep -q '"repo":' <<<"$repos"; then
        paste -d' ' \
            <(grep -o '"repo":"[^"]*"' <<<"$repos" | cut -d '"' -f4) \
            <(grep -o '"status":"[^"]*"' <<<"$repos" | cut -d '"' -f4) \
            2>/dev/null || printf '%s\n' "$repos"

        if grep -q '"status":"Failed"' <<<"$repos"; then
            fail 'at least one repository is unreachable'
            $K logs "deploy/$RELEASE-repo-server" --tail=30
        else
            ok 'all configured repositories are reachable'
        fi
    else
        echo 'no repositories configured yet (expected before the manifests repo exists)'
    fi
fi

hr 'app project'
if $K get appproject homelab >/dev/null 2>&1; then
    ok 'appproject/homelab present'
else
    fail 'appproject/homelab missing'
fi

hr 'pre-clean probe'
if ! kubectl delete -f "$MANIFEST" --ignore-not-found \
    --wait=true --timeout="$DELETE_TIMEOUT" >/dev/null 2>&1; then
    printf 'stale %s stuck in deletion. removing finalizer\n' "$APP" >&2
    remove_finalizers --wait=true --timeout=30s
fi
kubectl delete ns "$APP_NS" --ignore-not-found \
    --wait=true --timeout="$DELETE_TIMEOUT" >/dev/null 2>&1

hr 'end-to-end: sync a known-good public repo'
kubectl apply -f "$MANIFEST" || exit 1

sync_ok=1
if ! $K wait --for=jsonpath='{.status.sync.status}'=Synced \
    "application/$APP" --timeout="$SYNC_TIMEOUT"; then
    fail 'application never reached Synced'
    sync_ok=0
fi

if ! $K wait --for=jsonpath='{.status.health.status}'=Healthy \
    "application/$APP" --timeout="$SYNC_TIMEOUT"; then
    fail 'application never reached Healthy'
    sync_ok=0
fi

if [[ $sync_ok -eq 0 ]]; then
    debug_application
else
    ok 'Synced and Healthy'
fi

hr "resources actually exist in $APP_NS"
if [[ $sync_ok -eq 1 ]]; then
    $K_APP get all 2>/dev/null
    if $K_APP rollout status deploy/guestbook-ui --timeout="$GUESTBOOK_UI_TIMEOUT"; then
        ok 'guestbook-ui rolled out'
    else
        fail 'guestbook-ui did not become available'
        $K_APP describe deploy/guestbook-ui | tail -20
    fi
else
    echo 'skipping since application never synced'
fi

hr 'resources are tracked by argocd'
if [[ $sync_ok -eq 1 ]]; then
    tracked=$(
        $K_APP get deploy guestbook-ui \
            -o jsonpath='{.metadata.annotations.argocd\.argoproj\.io/tracking-id}' \
        2>/dev/null
    )
    if [[ -n "$tracked" ]]; then
        ok "tracking-id: $tracked"
    else
        fail 'no argocd tracking annotation. resourceTrackingMethod may be misconfigured'
    fi
else
    echo 'skipping since application never synced'
fi

hr 'self-heal'
if [[ $sync_ok -eq 1 ]]; then
    $K_APP scale deploy/guestbook-ui --replicas=3 >/dev/null
    healed=0
    for _ in {1..30}; do
        want=$(
            $K_APP get deploy guestbook-ui -o jsonpath='{.spec.replicas}' 2>/dev/null
        )
        [[ "$want" == '1' ]] && { healed=1; break; }
        sleep 3
    done

    if [[ $healed -eq 1 ]]; then
        ok 'controller reverted the out-of-band change'
    else
        fail "replicas still '${want:-<none>}' after 90s. selfHeal is not working"
    fi
else
    echo 'skipping since application never synced'
fi

hr 'prune on delete'
if kubectl delete -f "$MANIFEST" --wait=true --timeout="$DELETE_TIMEOUT"; then
    if $K_APP get deploy guestbook-ui >/dev/null 2>&1; then
        fail 'finalizer released but guestbook-ui still exists'
    else
        ok 'guestbook-ui pruned'
    fi
else
    fail "argo did not prune within $DELETE_TIMEOUT"

    debug_application
    remove_finalizers --wait=false
fi

hr 'result'
if [[ $rc -eq 0 ]]; then
    ok 'all checks passed'
else
    fail 'one or more checks failed'
fi

cat <<EOF

Node-local only. The check that matters runs from a connected WireGuard client
where dnsmasq supplies the name instead of curl --resolve:

    # expect $VIP
    dig +short $HOST

    # expect 200, valid cert, no warning
    curl -I https://$HOST/

EOF

exit $rc
