#!/usr/bin/env bash
# DAR-BE-169: re-runnable proof that the script worker's walls hold on the kind lab (see README.md).
#
# Every network wall is a pair: the attempt from inside the worker must FAIL and the same attempt from a control pod
# (darpan-lab, no special labels) must SUCCEED. If the control fails too the wall is INCONCLUSIVE, not PASS, so a
# broken lab, or a laptop without internet, cannot read as green.
#
#   k8s-lab/guardrail-check.sh            # exit 0 only when every check is PASS
#   MEM_MAX_BYTES=402653184 k8s-lab/guardrail-check.sh
set -uo pipefail

CTX=${KUBE_CONTEXT:-kind-darpan-lab}
WNS=darpan-scripts
RNS=darpan-lab
MEM_MAX_BYTES=${MEM_MAX_BYTES:-402653184}   # 384Mi, the lab's limit
EXTERNAL_IP=${EXTERNAL_IP:-1.1.1.1}
EXTERNAL_HOST=${EXTERNAL_HOST:-example.com}
K="kubectl --context $CTX"

pass=0; fail=0; unsure=0
report() {   # report <PASS|FAIL|INCONCLUSIVE> <wall> <detail>
  printf '%-13s %-44s %s\n' "$1" "$2" "$3"
  case $1 in PASS) pass=$((pass+1));; FAIL) fail=$((fail+1));; *) unsure=$((unsure+1));; esac
}

WORKER=$($K -n $WNS get pod -l app=script-worker --field-selector=status.phase=Running -o name | head -1)
ROOT=$($K -n $RNS get pod -l app=darpan-root --field-selector=status.phase=Running -o name | head -1)
[ -n "$WORKER" ] && [ -n "$ROOT" ] || { echo "worker or root pod not running in $CTX"; exit 2; }
WORKER_IP=$($K -n $WNS get "$WORKER" -o jsonpath='{.status.podIP}')
MYSQL_IP=$($K -n $RNS get svc mysql -o jsonpath='{.spec.clusterIP}')
API_IP=$($K -n default get svc kubernetes -o jsonpath='{.spec.clusterIP}')
DNS_IP=$($K -n kube-system get svc kube-dns -o jsonpath='{.spec.clusterIP}')

# The control pod uses the worker's own image (same tools) but sits in darpan-lab with no app label.
CONTROL=guardrail-control-$$
$K -n $RNS run "$CONTROL" --image=darpan-script-worker:lab --image-pull-policy=Never --restart=Never \
  --labels=app=guardrail-control --command -- sleep 600 >/dev/null
trap '$K -n $RNS delete pod "$CONTROL" --wait=false >/dev/null 2>&1' EXIT
$K -n $RNS wait --for=condition=Ready "pod/$CONTROL" --timeout=60s >/dev/null || { echo "control pod not ready"; exit 2; }

in_worker()  { $K -n $WNS exec "$WORKER" -- bash -c "$1" >/dev/null 2>&1; }
in_control() { $K -n $RNS exec "$CONTROL" -- bash -c "$1" >/dev/null 2>&1; }
tcp() { echo "timeout 4 bash -c 'exec 3<>/dev/tcp/$1/$2'"; }

# wall <name> <probe>: blocked from the worker, open from the control
wall() {
  local name=$1 probe=$2
  if in_worker "$probe"; then report FAIL "$name" "reachable from the worker"
  elif ! in_control "$probe"; then report INCONCLUSIVE "$name" "control could not reach it either"
  else report PASS "$name" "blocked from worker, open from control"; fi
}

echo "== network: nothing out of the worker"
wall "egress: MySQL ($MYSQL_IP:3306)"      "$(tcp "$MYSQL_IP" 3306)"
wall "egress: internet ($EXTERNAL_IP:443)" "$(tcp "$EXTERNAL_IP" 443)"
wall "egress: DNS lookup ($EXTERNAL_HOST)" "timeout 6 getent hosts $EXTERNAL_HOST"
wall "egress: cluster DNS ($DNS_IP:53)"    "$(tcp "$DNS_IP" 53)"
wall "egress: Kubernetes API ($API_IP)"    "$(tcp "$API_IP" 443)"
# kind has no cloud metadata service, so there is no control to compare with; AWS gets its own check.
if in_worker "$(tcp 169.254.169.254 80)"; then report FAIL "egress: cloud metadata (169.254.169.254)" "reachable"
else report PASS "egress: cloud metadata (169.254.169.254)" "blocked (no control on kind)"; fi

echo "== network: only root gets in"
if in_control "$(tcp "$WORKER_IP" 8090)"; then report FAIL "ingress: non-root pod -> worker:8090" "connected"
elif $K -n $RNS exec "$ROOT" -c darpan -- curl -sf -m 4 "http://$WORKER_IP:8090/health" >/dev/null 2>&1; then
  report PASS "ingress: non-root pod -> worker:8090" "refused, while root gets /health"
else report INCONCLUSIVE "ingress: non-root pod -> worker:8090" "root cannot reach the worker either"; fi

echo "== identity: nothing worth stealing, nothing to escalate"
check() {   # check <name> <command that must succeed inside the worker>
  if in_worker "$2"; then report PASS "$1" ok; else report FAIL "$1" "$3"; fi
}
check "uid is not root"               '[ "$(id -u)" != 0 ]'                                    "runs as uid 0"
check "no Linux capabilities"         'grep -q "^CapEff:[[:space:]]*0000000000000000$" /proc/self/status' "CapEff not empty"
check "no-new-privileges"             'grep -q "^NoNewPrivs:[[:space:]]*1$" /proc/self/status' "NoNewPrivs is 0"
check "root filesystem read-only"     '! touch /guardrail-probe 2>/dev/null'                   "/ is writable"
check "/tmp writable (control)"       'touch /tmp/guardrail-probe && rm /tmp/guardrail-probe'   "/tmp not writable: the RO check proves nothing"
check "no service-account token"      '[ ! -e /var/run/secrets/kubernetes.io ]'                 "token mounted"
# Names only, never values.
check "no secret-looking env vars"    '! env | cut -d= -f1 | grep -E -i "pass|secret|token|jwt|crypt|_key$|^Moqui_DB|^DB_"' "found secret-looking names"
check "memory cap <= $MEM_MAX_BYTES"  "m=\$(cat /sys/fs/cgroup/memory.max); [ \"\$m\" != max ] && [ \"\$m\" -le $MEM_MAX_BYTES ]" "no cgroup cap or above $MEM_MAX_BYTES"

echo "== function: the worker runs scripts and refuses escapes"
evaluate() {   # evaluate <json> -> worker reply, posted from the root pod
  printf '%s' "$1" | $K -n $RNS exec -i "$ROOT" -c darpan -- curl -s -m 10 -H 'Content-Type: application/json' \
    --data-binary @- "http://$WORKER_IP:8090/evaluate"
}
r=$(evaluate '{"profile":"EXPRESSION","body":"1 + 1","input":null}')
if echo "$r" | grep -q '"ok":true' && echo "$r" | grep -q '"result":2'; then report PASS "root -> worker evaluates (1 + 1)" "result 2"
else report FAIL "root -> worker evaluates (1 + 1)" "got: ${r:0:120}"; fi
r=$(evaluate "{\"profile\":\"SCRIPT\",\"body\":\"''.class.forName('java.lang.Runtime')\",\"input\":null}")
if echo "$r" | grep -q '"kind":"NOT_ALLOWED"'; then report PASS "escape attempt (forName Runtime) refused" NOT_ALLOWED
else report FAIL "escape attempt (forName Runtime) refused" "got: ${r:0:120}"; fi

echo
echo "PASS $pass   FAIL $fail   INCONCLUSIVE $unsure"
[ "$fail" -eq 0 ] && [ "$unsure" -eq 0 ]
