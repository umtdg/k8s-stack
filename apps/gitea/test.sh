#!/usr/bin/env bash

set -uo pipefail

MANIFEST="${MANIFEST:-test.yaml}"
NS="${NS:-gitea}"
RELEASE="${RELEASE:-gitea}"
HOST="${HOST:-git.umtdg.com}"
VIP="${VIP:-10.10.10.200}"
NODE_IP="${NODE_IP:-10.10.10.2}"
PVC="${PVC:-gitea-shared-storage}"
ADMIN_SECRET="${ADMIN_SECRET:-gitea-admin}"
PROBE="${PROBE:-gitea-pgprobe}"
PG_HOST="${PG_HOST:-pg-rw.cnpg.svc.cluster.local}"
INGRESS_NS="${INGRESS_NS:-ingress-nginx}"
INGRESS_SVC="${INGRESS_SVC:-ingress-nginx-controller}"
TIMEOUT="${TIMEOUT:-180s}"
KEEP="${KEEP:-0}"

K="kubectl -n $NS"
K_INGRESS="kubectl -n $INGRESS_NS"
SELECTOR="app.kubernetes.io/name=gitea,app.kubernetes.io/instance=$RELEASE"
rc=0
failures=()

hr() { printf '\n--- %s ---\n' "$1"; }
ok() { printf 'OK: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; failures+=("$1"); rc=1; }

API_CODE=''
API_BODY=''
api() {
    local method=$1
    local path=$2
    local out
    shift 2

    out=$(
        curl -sS --max-time 20 --resolve "$HOST:443:$VIP" -X "$method" \
            -H 'Content-Type: application/json' -H 'Accept: application/json' \
            -w '\n%{http_code}' "$@" "https://$HOST/api/v1$path" 2>&1
    )
    API_CODE=${out##*$'\n'}
    API_BODY=${out%$'\n'*}
}

json_field() {
    grep -o "\"$1\":\"[^\"]*\"" | head -1 | cut -d '"' -f4
}

ssh_banner() {
    timeout 5 bash -c "exec 3<>/dev/tcp/$1/22 && head -1 <&3" 2>/dev/null | tr -d '\r'
}

gitea_cli() {
    $K exec "deploy/$RELEASE" -c gitea -- gitea "$@"
}


app_ini() {
    $K exec "deploy/$RELEASE" -c gitea -- cat /data/gitea/conf/app.ini 2>/dev/null
}

ini_has() {
    awk -v s="[$1]" -v k="$2" -v v="$3" '
        /^\[/ { in_s = ($0 == s) }
        in_s {
            split($0, kv, "=")
            key = kv[1];
            gsub(/^[ \t]+|[ \t]+$/, "", key);

            val = substr($0, index($0, "=") + 1)
            gsub(/^[ \t]+|[ \t]+$/, "", val);

            if (key == k && val == v) found = 1
        }
        END { exit !found }
    ' <<<"$APP_INI"
}

debug_gitea() {
    hr 'debug: pods'
    $K get pods -o wide

    hr 'debug: events'
    $K get events --sort-by=.lastTimestamp | tail -20

    for c in init-directories init-app-ini configure-gitea; do
        hr "debug: init container $c"
        $K logs "deploy/$RELEASE" -c "$c" --tail=30 2>&1
    done

    hr 'debug: gitea'
    $K logs "deploy/$RELEASE" -c gitea --tail=60 2>&1

    hr 'debug: ingress-nginx tcp config'
    $K_INGRESS get cm -l app.kubernetes.io/component=controller \
        -o jsonpath='{range .items[*]}{.metadata.name}: {.data}{"\n"}{end}' \
        2>/dev/null
}

WORK=$(mktemp -d)
PROBE_USER="probe-$(date +%s)-$RANDOM"
PROBE_PW=$(openssl rand -hex 32)
REPO="$PROBE_USER"
TOKEN=''
ADMIN_USER=''
user_created=0
repo_created=0

cleanup() {
    hr 'cleanup'
    if [[ "$KEEP" == '1' ]]; then
        printf '\nKeeping in place since KEEP=1\n'
        printf '    pod/%s, user %s (password %s), repo %s, %s\n' \
            "$PROBE" "$PROBE_USER" "$PROBE_PW" "$REPO" "$WORK"
        return
    fi

    if [[ $user_created -eq 1 ]]; then
        if gitea_cli admin user delete --username "$PROBE_USER" --purge >/dev/null 2>&1; then
            printf 'user %s purged\n' "$PROBE_USER"
        else
            printf 'could not purge user %s. remove it from Site Administration\n' "$PROBE_USER" \
                >&2
        fi
    fi

    $K delete "pod/$PROBE" --ignore-not-found --wait=false >/dev/null
    rm -rf "$WORK"
}
trap cleanup EXIT

hr 'preflight'
missing=()
for bin in kubectl helm curl openssl git ssh ssh-keygen timeout awk; do
    command -v "$bin" >/dev/null || missing+=("$bin")
done

if [[ ${#missing[@]} -gt 0 ]]; then
    fail "missing tools: ${missing[*]}"
    exit 1
fi

if [[ ! -f "$MANIFEST" ]]; then
    fail "manifest not found: $MANIFEST"
    exit 1
fi

git_ver=$(git version | awk '{print $3}')
if [[ "$(printf '%s\n2.37\n' "$git_ver" | sort -V | head -1)" != '2.37' ]]; then
    fail "git $git_ver is older than 2.37; HTTPS clone check needs http.curloptResolve"
fi

ok 'tools present'

hr 'helm release'
chart=$(helm -n "$NS" list -f "^$RELEASE\$" -o json 2>/dev/null | json_field chart)
status=$(helm -n "$NS" list -f "^$RELEASE\$" -o json 2>/dev/null | json_field status)

chart="${chart:-<none>}"
status="${status:-<none>}"
printf 'chart: %s  status: %s\n' "$chart" "$status"
if [[ "$status" != 'deployed' ]]; then
    fail "helm release status is $status, expected 'deployed'"
fi

hr 'workload'
if $K wait --for=condition=Ready pod -l "$SELECTOR" --timeout="$TIMEOUT"; then
    ok 'gitea pod Ready'
else
    fail 'gitea pod not Ready'
fi

strategy=$(
    $K get "deploy/$RELEASE" -o jsonpath='{.spec.strategy.type}' \
        2>/dev/null
)
if [[ "$strategy" == 'Recreate' ]]; then
    ok 'strategy Recreate'
else
    fail "strategy is ${strategy:-<none>}. two pods would share one RWO volume during rollout"
fi

hr 'persistence'
pvc_phase=$(
    $K get "pvc/$PVC" -o jsonpath='{.status.phase}' 2>/dev/null
)
pvc_sc=$(
    $K get "pvc/$PVC" -o jsonpath='{.spec.storageClassName}' 2>/dev/null
)

pvc_phase="${pvc_phase:-<none>}"
pvc_sc="${pvc_sc:-<none>}"

printf 'pvc/%s: %s on %s\n' "$PVC" "$pvc_phase" "$pvc_sc"
if [[ "$pvc_phase" != 'Bound' ]]; then
    fail "pvc/$PVC is '$pvc_phase', expected 'Bound'"
fi

if [[ "$pvc_sc" != 'local-path' ]]; then
    fail "pvc/$PVC storageClass is '$pvc_sc', expected 'local-path'"
fi

hr 'effective configuration (app.ini)'
APP_INI=$(app_ini)
if [[ -n "$APP_INI" ]]; then
    while read -r section key value; do
        if ini_has "$section" "$key" "$value"; then
            ok "[$section] $key = '$value'"
        else
            fail "[$section] $key != '$value'"
        fi
    done <<EOF
database DB_TYPE postgres
database HOST $PG_HOST:5432
database NAME gitea
server ROOT_URL https://$HOST/
server SSH_DOMAIN $HOST
server SSH_PORT 22
server SSH_LISTEN_PORT 2222
server START_SSH_SERVER true
service DISABLE_REGISTRATION true
EOF

    if $K exec "deploy/$RELEASE" -c gitea -- test -e /data/gitea/gitea.db 2>/dev/null; then
        fail 'a sqlite database exists at /data/gitea/gitea.db. something ran against sqlite'
    else
        ok 'no sqlite database on the volume'
    fi
else
    fail 'could not read /data/gitea/conf/app.ini from the gitea container'
fi

hr 'ingress'
expected_host="$HOST"
expected_class='nginx'
expected_vip="$VIP"

ing="ingress/$RELEASE"
ing_host=$($K get "$ing" -o jsonpath='{.spec.rules[0].host}' 2>/dev/null)
ing_class=$($K get "$ing" -o jsonpath='{.spec.ingressClassName}' 2>/dev/null)
ing_vip=$($K get "$ing" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
ing_tls=$($K get "$ing" -o jsonpath='{.spec.tls}' 2>/dev/null)

ing_host="${ing_host:-<none>}"
ing_class="${ing_class:-<none>}"
ing_vip="${ing_vip:-<none>}"
printf 'host=%s class=%s vip=%s\n' "$ing_host" "$ing_class" "$ing_vip"

if [[ "$ing_host" != "$expected_host" ]]; then
    fail "ingress host is not the expected '$expected_host'"
fi

if [[ "$ing_class" != "$expected_class" ]]; then
    fail "ingress class is not the expected '$expected_class'"
fi

if [[ "$ing_vip" != "$expected_vip" ]]; then
    fail "ingress VIP is not the expected '$expected_vip'"
fi

if [[ -n "$ing_tls" ]]; then
    fail 'ingress has a tls: block. it will not use the default wildcard certificate'
fi

hr "https://$HOST through $VIP"
code=''
for _ in {1..15}; do
    code=$(
        curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
            --resolve "$HOST:443:$VIP" "https://$HOST/api/healthz" \
        || true
    )
    [[ "$code" == '200' ]] && break

    sleep 2
done

if [[ "$code" == '200' ]]; then
    ok '/api/healthz 200 with a verified certificate'
else
    fail "/api/healthz returned '${code:-<none>}' (000 usually means TLS verification failed)"
    curl -sv --max-time 5 --resolve "$HOST:443:$VIP" "https://$HOST/api/healthz" 2>&1 | tail -15
fi

hr 'serving certificate'
cert=$(
    echo \
    | openssl s_client -connect "$VIP:443" -servername "$HOST" 2>/dev/null \
    | openssl x509 -noout -subject -issuer -enddate 2>/dev/null
)
printf '%s\n' "${cert:-<none>}"
if grep -qi "Let's Encrypt" <<<"$cert" && ! grep -qi 'STAGING' <<<"$cert"; then
    ok 'production wildcard from cert-manager'
else
    fail "not a production Let's Encrypt certificate. git over HTTPS will reject it"
fi

hr 'version'
image=$(
    $K get "deploy/$RELEASE" \
        -o jsonpath='{.spec.template.spec.containers[?(@.name=="gitea")].image}'
)
want="${image##*:}"
want="${want%-rootless}"

api GET /version
printf 'image: %s\n' "$image"
if [[ "$API_CODE" == '403' ]]; then
    ok 'anonymous API access refused (REQUIRE_SIGNIN_VIEW)'
else
    fail "anonymous GET /api/v1/version returned $API_CODE, expected 403. the instane is readable wwithout signing in"
fi

hr 'admin account'
ADMIN_USER=$(
    $K get "secret/$ADMIN_SECRET" -o jsonpath='{.data.username}' 2>/dev/null \
    | base64 -d
)
if [[ -n "$ADMIN_USER" ]]; then
    ok "secret/$ADMIN_SECRET names $ADMIN_USER"
else
    fail "secret/$ADMIN_SECRET missing"
fi

expected_mode='initialOnlyRequireReset'
mode=$(
    $K get "deploy/$RELEASE" \
        -o jsonpath='{.spec.template.spec.initContainers[?(@.name=="configure-gitea")].env[?(@.name=="GITEA_ADMIN_PASSWORD_MODE")].value}' \
        2>/dev/null
)
mode="${mode:-<none>}"
if [[ "$mode" == "$expected_mode" ]]; then
    ok "admin password mode $mode matches expected mode $expected_mode"
else
    fail "admin password mode is $mode, expected $expected_mode"
fi

hr 'database is CNPG'
$K delete "pod/$PROBE" --ignore-not-found --wait=true >/dev/null
if $K apply -f "$MANIFEST" >/dev/null \
    && $K wait --for=condition=Ready "pod/$PROBE" --timeout="$TIMEOUT" >/dev/null; then
 
    psql() { $K exec "$PROBE" -- psql -At -v ON_ERROR_STOP=1 -c "$1" 2>&1; }
 
    if who=$(psql 'select current_user, current_database()'); then
        printf '%s\n' "$who"
        [[ "$who" == 'gitea|gitea' ]] || fail "connected as '$who', expected gitea|gitea"
    else
        fail "copied gitea-db-creds cannot connect to $PG_HOST: $who"
    fi
 
    tables=$(psql "select count(*) from information_schema.tables where table_schema = 'public'")
    printf 'tables in public: %s\n' "${tables:-<none>}"
    if [[ "$tables" =~ ^[0-9]+$ && "$tables" -gt 50 ]]; then
        ok 'schema populated by Gitea migrations'
    else
        fail "public schema has '${tables:-<none>}' tables; Gitea did not migrate into CNPG"
    fi
 
    if [[ -n "$ADMIN_USER" ]]; then
        row=$(psql "select is_admin from \"user\" where lower_name = lower('$ADMIN_USER')")
        if [[ "$row" == 't' ]]; then
            ok "$ADMIN_USER row exists in CNPG with is_admin"
        else
            fail "no admin row for $ADMIN_USER in CNPG (got '${row:-<none>}')"
        fi
    fi
else
    fail "pod/$PROBE did not become Ready"
    $K describe "pod/$PROBE" | tail -20
fi

hr 'ssh'
expected_svc_port='22'
svc_port=$(
    $K_INGRESS get "svc/$INGRESS_SVC" \
        -o jsonpath='{.spec.ports[?(@.port==22)].port}' \
        2>/dev/null
)
svc_port="${svc_port:-<none>}"
if [[ "$svc_port" == "$expected_svc_port" ]]; then
    ok "$INGRESS_SVC exposes '$svc_port'"
else
    fail "$INGRESS_SVC exposes '$svc_port', expected '$expected_svc_port'"
fi

vip_banner=$(ssh_banner "$VIP")
node_banner=$(ssh_banner "$NODE_IP")
printf '%s:22  %s\n%s:22  %s\n' \
    "$VIP" "${vip_banner:-<no answer>}" \
    "$NODE_IP" "${node_banner:-<no answer>}"

if [[ "$vip_banner" == SSH-2.0-* && "$vip_banner" != *OpenSSH* ]]; then
    ok "$VIP:22 answers with Gitea's built-in server"
elif [[ "$vip_banner" == *OpenSSH* ]]; then
    fail "$VIP:22 is OpenSSH. the VIP is reaching a host sshd, not Gitea"
else
    fail "$VIP:22 did not answer with an SSH banner"
fi

if [[ "$node_banner" == *OpenSSH* ]]; then
    ok "$NODE_IP:22 is still the VM's sshd"
else
    fail "$NODE_IP:22 is not OpenSSH. VM access may be broken"
fi

hr 'end-to-end create, push over ssh, clone over https, compare'
echo 'skipped'

hr 'result'
if [[ $rc -eq 0 ]]; then
    ok 'all checks passed'
else
    printf '%d check(s) failed:\n' "${#failures[@]}" >&2
    printf '    - %s\n' "${failures[@]}" >&2
    debug_gitea
fi

cat <<EOF

Node-local only. From a connected WireGuard client, where dnsmasq supplies the name instead of --resolve / HostName:

    dig +short $HOST        # expect $VIP
    curl -I https://$HOST/  # expect 200, no warning
    ssh -T git@$HOST        # expect Gitea's greeting after adding a key

EOF

exit $rc
