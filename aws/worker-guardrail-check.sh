#!/usr/bin/env bash
# DAR-BE-169: re-runnable proof that the script worker's walls hold on AWS UAT (ECS Fargate), the counterpart of
# k8s-lab/guardrail-check.sh. Fargate has no exec-into-anything here, so the attempts run as one-off probe tasks: a
# clone of the LIVE worker task definition (same uid, read-only root, dropped capabilities, memory cap, no task role)
# with only the entrypoint changed to aws/worker-probe.sh, started from three network positions:
#
#   worker   the worker's subnet + security group (no internet VPC, DNS Firewall)  -> every wall must hold here
#   control  Moqui's public subnet + security group                                -> must reach what the worker cannot
#   other    Moqui's VPC, the load balancer's security group (not Moqui)           -> must be refused by the worker
#
# A wall the control cannot cross either reports INCONCLUSIVE, never PASS.
#   aws/worker-guardrail-check.sh            # exit 0 only when every check is PASS; ~3 min, three 0.25-vCPU tasks
set -uo pipefail
cd "$(dirname "$0")"
STACK=${STACK:-darpan-uat}; REGION=${AWS_REGION:-us-east-2}; PROFILE=${AWS_PROFILE:-darpan}
MEM_MAX_BYTES=${MEM_MAX_BYTES:-402653184}   # 384 MiB, the worker container's Memory
A="aws --profile $PROFILE --region $REGION --output text"

out() { $A cloudformation describe-stacks --stack-name "$STACK" --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue"; }
res() { $A cloudformation describe-stack-resource --stack-name "$STACK" --logical-resource-id "$1" --query StackResourceDetail.PhysicalResourceId; }
task_ip() { $A ecs describe-tasks --cluster "$CLUSTER" --tasks "$1" \
  --query "tasks[0].attachments[0].details[?name=='privateIPv4Address'].value"; }

CLUSTER=$(out ClusterName); WORKER_TD=$(out WorkerTaskDefinitionArn); WORKER_URL=$(out WorkerUrl)
[ -n "$WORKER_TD" ] && [ "$WORKER_TD" != None ] || { echo "WorkerEnabled is not true on $STACK"; exit 2; }
W_SUBNET=$(out WorkerSubnetId); W_SG=$(out WorkerSecurityGroupId)
C_SUBNET=$(res PublicSubnetA); C_SG=$(res AppSecurityGroup); O_SG=$(res AlbSecurityGroup)
DB_IP=$(dig +short "$(out DatabaseEndpoint)" | tail -1)
SEARCH_IP=$(dig +short "$(out SearchEndpoint | sed 's#https://##')" | tail -1)
ROOT_TASK=$($A ecs list-tasks --cluster "$CLUSTER" --service-name "$(out ServiceName)" --desired-status RUNNING --query 'taskArns[0]')
WORKER_TASK=$($A ecs list-tasks --cluster "$CLUSTER" --service-name "$(res WorkerService)" --desired-status RUNNING --query 'taskArns[0]')
ROOT_IP=$(task_ip "$ROOT_TASK"); WORKER_IP=$(task_ip "$WORKER_TASK")
for v in DB_IP SEARCH_IP ROOT_IP WORKER_IP; do [ -n "${!v}" ] && [ "${!v}" != None ] || { echo "could not find $v"; exit 2; }; done
echo "targets: db $DB_IP  search $SEARCH_IP  moqui $ROOT_IP:8080  worker $WORKER_IP:8090 ($WORKER_URL)"

# Probe task definition = the live worker's, entrypoint swapped. Deregistered on exit.
WORK=$(mktemp -d); trap 'rm -rf "$WORK"; [ -n "${PROBE_TD:-}" ] && $A ecs deregister-task-definition --task-definition "$PROBE_TD" >/dev/null' EXIT
$A ecs describe-task-definition --task-definition "$WORKER_TD" --output json > "$WORK/td.json"
python3 -I - "$WORK/td.json" "$WORK/probe-td.json" "$(cat worker-probe.sh)" <<'EOF'
import json, sys
td = json.load(open(sys.argv[1]))['taskDefinition']
keep = ['family', 'taskRoleArn', 'executionRoleArn', 'networkMode', 'containerDefinitions', 'volumes',
        'requiresCompatibilities', 'cpu', 'memory', 'runtimePlatform']
out = {k: td[k] for k in keep if k in td}
out['family'] = td['family'] + '-probe'
c = out['containerDefinitions'][0]
c['entryPoint'] = ['bash', '-c']
c['command'] = [sys.argv[3]]
c.pop('healthCheck', None)   # the probe is not the server; nothing else about the container changes
json.dump(out, open(sys.argv[2], 'w'))
EOF
PROBE_TD=$($A ecs register-task-definition --cli-input-json "file://$WORK/probe-td.json" --query taskDefinition.taskDefinitionArn)

ONE_JSON='{"profile":"EXPRESSION","body":"1 + 1","input":null}'
ESC_JSON="{\"profile\":\"SCRIPT\",\"body\":\"''.class.forName('java.lang.Runtime')\",\"input\":null}"
run_probe() {   # run_probe <position> <subnet> <sg> <ENABLED|DISABLED>
  local env; env=$(python3 -I -c 'import json,sys; print(json.dumps({"containerOverrides":[{"name":"worker","environment":[
    {"name":k,"value":v} for k,v in zip(sys.argv[1::2], sys.argv[2::2])]}]}))' \
    PROBE_POSITION "$1" MYSQL_IP "$DB_IP" SEARCH_IP "$SEARCH_IP" ROOT_IP "$ROOT_IP" WORKER_IP "$WORKER_IP" \
    WORKER_URL "$WORKER_URL" AWS_REGION_NAME "$REGION" MEM_MAX_BYTES "$MEM_MAX_BYTES" ONE_JSON "$ONE_JSON" ESC_JSON "$ESC_JSON")
  $A ecs run-task --cluster "$CLUSTER" --task-definition "$PROBE_TD" --launch-type FARGATE --started-by guardrail-probe \
    --network-configuration "awsvpcConfiguration={subnets=[$2],securityGroups=[$3],assignPublicIp=$4}" \
    --overrides "$env" --query 'tasks[0].taskArn'
}
T_W=$(run_probe worker "$W_SUBNET" "$W_SG" DISABLED)
T_C=$(run_probe control "$C_SUBNET" "$C_SG" ENABLED)
T_O=$(run_probe other "$C_SUBNET" "$O_SG" ENABLED)
echo "probes: $T_W $T_C $T_O  (waiting for them to stop)"
$A ecs wait tasks-stopped --cluster "$CLUSTER" --tasks "$T_W" "$T_C" "$T_O"
GROUP=$($A ecs describe-task-definition --task-definition "$PROBE_TD" \
  --query 'taskDefinition.containerDefinitions[0].logConfiguration.options."awslogs-group"')
for p in W C O; do t=T_$p; arn=${!t}; id=${arn##*/}
  $A logs get-log-events --log-group-name "$GROUP" --log-stream-name "worker/worker/$id" --query 'events[].message' \
    | tr '\t' '\n' > "$WORK/$p.log" 2>/dev/null
  grep -q '^END$' "$WORK/$p.log" || { echo "probe $p did not finish:"; $A ecs describe-tasks --cluster "$CLUSTER" --tasks "${!t}" \
    --query 'tasks[0].[stoppedReason,containers[0].exitCode,containers[0].reason]'; }
done
got() { awk -v n="$2" '$1=="R" && $2==n {print $3}' "$WORK/$1.log"; }   # got <W|C|O> <name> -> 0 worked, 1 not

pass=0; fail=0; unsure=0
report() { printf '%-13s %-46s %s\n' "$1" "$2" "$3"
  case $1 in PASS) pass=$((pass+1));; FAIL) fail=$((fail+1));; *) unsure=$((unsure+1));; esac; }
wall() {   # wall <label> <attempt> <control position>
  local w c; w=$(got W "$2"); c=$(got "$3" "$2")
  if [ "$w" = 0 ]; then report FAIL "$1" "reachable from the worker"
  elif [ "$w" != 1 ] || [ "$c" != 0 ]; then report INCONCLUSIVE "$1" "worker=${w:-none} control=${c:-none}"
  else report PASS "$1" "blocked from worker, open from $( [ "$3" = C ] && echo Moqui || echo ALB-group )"; fi; }
check() { if [ "$(got W "$2")" = 0 ]; then report PASS "$1" ok; else report FAIL "$1" "${3:-not true}"; fi; }

echo "== network: nothing out of the worker"
wall "egress: MySQL ($DB_IP:3306)"        mysql      C
wall "egress: OpenSearch ($SEARCH_IP:443)" search    C
wall "egress: internet (1.1.1.1:443)"     inet_ip    C
wall "egress: internet (https://example.com)" inet_https C
wall "egress: DNS lookup (example.com)"   dns_ext    C
wall "egress: Moqui itself ($ROOT_IP:8080)" root_http O
if [ "$(got W imds)" = 1 ]; then report PASS "egress: instance metadata (169.254.169.254)" "unreachable (Fargate has none)"
else report FAIL "egress: instance metadata (169.254.169.254)" "worker=$(got W imds)"; fi
# S3 is checked statically: S3 answers NoSuchBucket for a made-up bucket BEFORE it evaluates any policy, so a live
# write test needs a real bucket that grants access (not set up; see README gaps).
s3pol=$($A ec2 describe-vpc-endpoints --vpc-endpoint-ids "$(res WorkerS3Endpoint)" --query 'VpcEndpoints[0].PolicyDocument')
if python3 -I -c 'import json,sys
d=json.loads(sys.argv[1]); a=[x for x in d["Statement"] if x["Effect"]=="Allow"]
ok=len(a)==1 and a[0].get("Action") in ("s3:GetObject",["s3:GetObject"]) and a[0].get("Resource") in (sys.argv[2],[sys.argv[2]])
sys.exit(0 if ok else 1)' "$s3pol" "arn:aws:s3:::prod-$REGION-starport-layer-bucket/*"; then
  report PASS "S3 endpoint policy (static)" "only s3:GetObject on the ECR layer bucket"
else report FAIL "S3 endpoint policy (static)" "policy allows more than layer reads"; fi
check "DNS allow-list: ECR resolves to the endpoint (10.41.x)" ecr_private "the worker could not start without it"

echo "== network: only Moqui gets in"
if [ "$(got O worker_tcp)" = 0 ]; then report FAIL "ingress: ALB group -> worker:8090" connected
elif [ "$(got C worker_tcp)" != 0 ]; then report INCONCLUSIVE "ingress: ALB group -> worker:8090" "Moqui's group cannot reach it either"
else report PASS "ingress: ALB group -> worker:8090" "refused, while Moqui's group connects"; fi
if [ "$(got W worker_tcp)" = 0 ]; then report FAIL "ingress: worker VPC neighbour -> worker:8090" connected
else report PASS "ingress: worker VPC neighbour -> worker:8090" refused; fi

echo "== identity: nothing worth stealing, nothing to escalate"
check "uid is not root"            not_root     "runs as uid 0"
check "no Linux capabilities"      no_caps      "CapEff not empty"
check "root filesystem mounted read-only" ro_root "/ is mounted rw"
check "no secret-looking env vars" no_secret_env "found: $(awk '$1=="E"{$1=""; print}' "$WORK/W.log")"
echo "info          writable paths for uid 10001                 $(awk '$1=="W"{$1=""; print}' "$WORK/W.log" | sed 's/^ *$/none/')"
check "no AWS credentials"         no_aws_creds "credentials reachable"
check "memory cap <= $MEM_MAX_BYTES" mem_cap    "cap $(awk '$1=="M"{print $2; exit}' "$WORK/W.log")"
# Fargate offers no no-new-privileges switch; reported, not counted (uid 10001 + no capabilities is the wall).
echo "info          no-new-privileges flag                         $( [ "$(got W no_new_privs)" = 0 ] && echo set || echo 'not set (Fargate has no knob)')"

echo "== function: Moqui's group reaches the worker by name and it refuses escapes"
one=$(awk '$1=="F" && $2=="one"' "$WORK/C.log"); esc=$(awk '$1=="F" && $2=="esc"' "$WORK/C.log")
if echo "$one" | grep -q '"ok":true' && echo "$one" | grep -q '"result":2'; then report PASS "Moqui group -> $WORKER_URL (1 + 1)" "result 2"
else report FAIL "Moqui group -> $WORKER_URL (1 + 1)" "got: ${one:0:120}"; fi
if echo "$esc" | grep -q '"kind":"NOT_ALLOWED"'; then report PASS "escape attempt (forName Runtime) refused" NOT_ALLOWED
else report FAIL "escape attempt (forName Runtime) refused" "got: ${esc:0:120}"; fi

echo; echo "PASS $pass   FAIL $fail   INCONCLUSIVE $unsure"
[ "$fail" -eq 0 ] && [ "$unsure" -eq 0 ]
