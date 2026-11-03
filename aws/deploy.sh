#!/usr/bin/env bash
# Deploy the Darpan backend to Darpan's own AWS (DAR-OPS-006): build -> push -> roll the ECS service.
#
#   aws/deploy.sh <uat|prod> [options]        (run from anywhere; bash 3.2 safe for macOS)
#
# How a deploy works
#   1. Builds the image from THIS repo at a git ref for linux/arm64 on aws/base.Dockerfile: in AWS CodeBuild
#      (stack <env>-build, aws/darpan-build.yaml; default when it exists) or locally in a throwaway worktree
#      (never your working tree). The Dockerfiles clone components with `git clone -b <branch>`,
#      so a cached clone layer would silently ship an old main: an ARG inserted before the clone step busts
#      the cache from there on, while the OS/JDK layers stay cached (and are not re-uploaded).
#   2. Pushes it to the target's ECR repo under a fresh, never-reused tag: <env>-<ref>-<UTC time>-<sha7>.
#   3. Creates a CloudFormation change set on the EXISTING template (--use-previous-template) that changes
#      only ImageTag (plus any --set). It refuses if anything beyond the service/task (and the resources a
#      --set is expected to touch) would change. Infra changes go through their own reviewed change sets.
#   4. Without --yes it prints that change set and stops (exit 6). With --yes it executes, waits for the
#      stack, waits for the ECS service to be stable, and checks <BaseUrl>/Login answers 200.
#   Deploys replace the single task in place (no overlap: Moqui's scheduler runs in-process), so expect
#   a few minutes of downtime per deploy. Rollback = deploy a previous tag with --tag.
#
# No secrets and no client names belong in this file: the repo is public.
set -euo pipefail

REGION=us-east-2
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
SETTABLE="DesiredCount SchedulerEnabled HostName AllowedCidr AllowOrigins UpgradeDataTypes TaskCpu TaskMemory"

usage() {
  cat <<'EOF'
Usage: aws/deploy.sh <uat|prod> [options]

  --ref <git-ref>     darpan-docker-config ref to build. uat: defaults to origin/main.
                      prod: REQUIRED (the current v0.0.x dummy tag for main, or a v2.x.y release tag).
  --tag <image-tag>   skip the build; deploy an image tag that is already in the target's ECR repo
                      (the second half of a plan-then-apply, or a rollback).
  --builder <b>       codebuild: build + push inside AWS (stack <env>-build, aws/darpan-build.yaml; the ref
                      must be on GitHub). local: build here and upload (slow from a home connection).
                      Default: codebuild when the target has the build project, else local.
  --maven-mirror      resolve Maven Central through Google's mirror (use when Central answers 429).
  --set KEY=VALUE     also change a stack parameter (repeatable). Allowed: DesiredCount SchedulerEnabled
                      HostName AllowedCidr AllowOrigins UpgradeDataTypes TaskCpu TaskMemory
  --restart           replace the running task on the image it already runs (no build, no change set):
                      re-runs the boot's upgrade-data load. Needs --yes.
  --yes               execute the change set. Without it: build + push (if needed), print the plan, stop.
  -h, --help

Exit: 0 deployed or nothing to change · 2 usage · 3 wrong account / no credentials · 4 build or push failed
      5 change set touches more than expected · 6 plan shown, re-run with --tag <tag> --yes · 7 unhealthy
EOF
}

die() { local code=$1; shift; echo "deploy: $*" >&2; exit "$code"; }
log() { echo "==> $*"; }

[ $# -ge 1 ] || { usage; exit 2; }
case "$1" in -h|--help) usage; exit 0 ;; esac
ENVNAME=$1; shift
# Expected AWS account per target, kept out of this public repo: aws/accounts.env (gitignored by *.env),
# or the same variables in the environment. The check stops a UAT command from ever landing on prod.
#   DARPAN_UAT_ACCOUNT=<12 digits>
#   DARPAN_PROD_ACCOUNT=<12 digits>
ACCOUNTS_FILE=${DARPAN_AWS_ACCOUNTS_FILE:-$SCRIPT_DIR/accounts.env}
if [ -f "$ACCOUNTS_FILE" ]; then . "$ACCOUNTS_FILE"; fi
case "$ENVNAME" in
  uat)  PROFILE=darpan;      ACCOUNT=${DARPAN_UAT_ACCOUNT:-};  STACK=darpan-uat;  ECR_REPO=darpan-uat/darpan
        DOCKERFILE=docker/Dockerfile;      DEFAULT_REF=origin/main; BUILD_PROJECT=darpan-uat-build ;;
  prod) PROFILE=darpan-prod; ACCOUNT=${DARPAN_PROD_ACCOUNT:-}; STACK=darpan-prod; ECR_REPO=darpan-prod/darpan
        DOCKERFILE=docker/prod/Dockerfile; DEFAULT_REF=;            BUILD_PROJECT=darpan-prod-build ;;
  *) usage; exit 2 ;;
esac
[ -n "$ACCOUNT" ] || die 3 "no expected account for $ENVNAME: set DARPAN_$(echo "$ENVNAME" | tr a-z A-Z)_ACCOUNT in $ACCOUNTS_FILE (gitignored)"

REF=$DEFAULT_REF; TAG=; MIRROR=0; YES=0; SETS=(); BUILDER=; RESTART=0
while [ $# -gt 0 ]; do
  case "$1" in
    --restart) RESTART=1; shift ;;
    --ref) REF=${2:?--ref needs a value}; shift 2 ;;
    --builder) BUILDER=${2:?--builder needs codebuild or local}; shift 2 ;;
    --tag) TAG=${2:?--tag needs a value}; shift 2 ;;
    --maven-mirror) MIRROR=1; shift ;;
    --set) SETS+=("${2:?--set needs KEY=VALUE}"); shift 2 ;;
    --yes) YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die 2 "unknown option: $1" ;;
  esac
done
if [ "$RESTART" = 1 ]; then
  [ -z "$TAG" ] && [ ${#SETS[@]} -eq 0 ] || die 2 "--restart takes no --tag or --set (it keeps the running image and parameters)"
  REF=x  # nothing to build
fi
[ -n "$TAG" ] || [ -n "$REF" ] || die 2 "prod needs --ref (e.g. the current v0.0.x dummy tag or a release tag) or --tag"
for kv in ${SETS[@]+"${SETS[@]}"}; do
  k=${kv%%=*}
  case "$kv" in *=*) ;; *) die 2 "--set wants KEY=VALUE, got: $kv" ;; esac
  case " $SETTABLE " in *" $k "*) ;; *) die 2 "--set $k is not allowed (allowed: $SETTABLE)" ;; esac
  if [ "$k" = DesiredCount ] && [ "${kv#*=}" != 0 ] && [ "${kv#*=}" != 1 ]; then
    die 2 "DesiredCount must be 0 or 1 (the in-process scheduler must never run twice)"
  fi
done

# Inside AWS (the darpan-<env>-deployer CodeBuild project, aws/darpan-deployer.yaml) the build role's own
# credentials are used; on a laptop, the named CLI profile.
if [ -n "${CODEBUILD_BUILD_ID:-}" ]; then
  unset AWS_PROFILE; export AWS_REGION=$REGION AWS_PAGER=""
  PROFILE="(CodeBuild role)"
else
  export AWS_PROFILE=$PROFILE AWS_REGION=$REGION AWS_PAGER=""
fi
WORK=$(mktemp -d "${TMPDIR:-/tmp}/darpan-deploy.XXXXXX")
WT=
cleanup() {
  if [ -n "$WT" ]; then git -C "$REPO_ROOT" worktree remove --force "$WT" >/dev/null 2>&1 || true; fi
  rm -rf "$WORK"
}
trap cleanup EXIT

# ---------- preflight: right account ----------
got=$(aws sts get-caller-identity --query Account --output text 2>/dev/null) \
  || die 3 "no AWS credentials for profile $PROFILE: run 'aws login --profile $PROFILE' and let it finish"
[ "$got" = "$ACCOUNT" ] || die 3 "profile $PROFILE is account $got, expected $ACCOUNT ($ENVNAME)"
REGISTRY=$ACCOUNT.dkr.ecr.$REGION.amazonaws.com
log "$ENVNAME: account $ACCOUNT, stack $STACK, registry $REGISTRY/$ECR_REPO"

out() { aws cloudformation describe-stacks --stack-name "$STACK" --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" --output text; }
service_ids() { CLUSTER=$(out ClusterName); SERVICE=$(out ServiceName); BASE=$(out BaseUrl); }

# After a new task was asked for at epoch-ms $1: service stable, /Login 200, and the boot's data load skipped
# no file (Moqui logs "Skipping to next file after error" and carries on, so the app still answers 200).
verify() {
  local since=$1 code=000 bad
  log "waiting for the ECS service to settle"
  aws ecs wait services-stable --cluster "$CLUSTER" --services "$SERVICE" \
    || die 7 "service not stable; logs: aws logs tail /ecs/$STACK/darpan --since 15m --profile $PROFILE"
  # /Login from here; when this runner cannot reach the ALB at all (000: its AllowedCidr admits one office IP,
  # not a CodeBuild host), the ALB's own health check of the target stands in.
  local tg
  tg=$(aws cloudformation describe-stack-resource --stack-name "$STACK" --logical-resource-id TargetGroup \
        --query StackResourceDetail.PhysicalResourceId --output text 2>/dev/null || true)
  for _ in $(seq 1 40); do
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$BASE/Login" || true)
    [ "$code" = 200 ] && break
    if [ "$code" = 000 ] && [ -n "$tg" ] && [ "$(aws elbv2 describe-target-health --target-group-arn "$tg" \
         --query 'length(TargetHealthDescriptions[?TargetHealth.State==`healthy`])' --output text 2>/dev/null)" -ge 1 ] 2>/dev/null; then
      log "$BASE is not reachable from this runner; the ALB reports the target healthy"
      code=200; break
    fi
    sleep 15
  done
  [ "$code" = 200 ] || die 7 "$BASE/Login answered $code after ~10 min; logs: aws logs tail /ecs/$STACK/darpan --since 15m --profile $PROFILE"
  bad=$(aws logs filter-log-events --log-group-name "/ecs/$STACK/darpan" --start-time "$since" \
        --filter-pattern '"Skipping to next file"' --query 'events[].message' --output text 2>/dev/null || true)
  if [ -n "$bad" ] && [ "$bad" != None ]; then
    printf '%s\n' "$bad" | tr '\t' '\n' | grep -o -E 'Error loading entity data from [^ ]+' | sort -u | sed 's/^/    skipped: /' >&2
    die 7 "$BASE/Login is 200, but the boot's data load skipped the file(s) above (FK order or bad data)"
  fi
}

# ---------- restart: same image, same parameters ----------
if [ "$RESTART" = 1 ]; then
  service_ids
  CUR=$(aws cloudformation describe-stacks --stack-name "$STACK" --query "Stacks[0].Parameters[?ParameterKey=='ImageTag'].ParameterValue" --output text)
  if [ "$YES" != 1 ]; then
    echo "Plan: replace the running $STACK task on its current image $CUR (a few minutes of downtime)."
    echo "To restart: aws/deploy.sh $ENVNAME --restart --yes"
    exit 6
  fi
  T0=$(( $(date +%s) * 1000 ))
  aws ecs update-service --cluster "$CLUSTER" --service "$SERVICE" --force-new-deployment >/dev/null
  log "restarting $STACK on $CUR"
  verify "$T0"
  log "restarted: $STACK runs $CUR; $BASE/Login 200; boot data loaded without skipped files"
  exit 0
fi

# ---------- build + push ----------
if [ -z "$TAG" ]; then
  git -C "$REPO_ROOT" fetch --quiet --tags origin || die 4 "git fetch failed in $REPO_ROOT"
  SHA=$(git -C "$REPO_ROOT" rev-parse --verify --quiet "$REF^{commit}") || die 2 "unknown ref: $REF"
  REFNAME=$(printf '%s' "${REF#origin/}" | tr -c 'A-Za-z0-9._-' '-')
  TAG="$ENVNAME-$REFNAME-$(date -u +%Y%m%d%H%M)-${SHA:0:7}"
  if [ -z "$BUILDER" ]; then
    if [ "$(aws codebuild batch-get-projects --names "$BUILD_PROJECT" --query 'length(projects)' --output text 2>/dev/null)" = 1 ]; then
      BUILDER=codebuild; else BUILDER=local; fi
  fi
fi

if [ -z "${SHA:-}" ]; then
  : # --tag given: nothing to build
elif [ "$BUILDER" = codebuild ]; then
  # CodeBuild clones the public repo itself, so the commit must be on GitHub.
  if ! git -C "$REPO_ROOT" branch -r --contains "$SHA" 2>/dev/null | grep -q . \
     && ! git -C "$REPO_ROOT" ls-remote origin 2>/dev/null | grep -q "^$SHA"; then
    die 2 "$SHA is not on GitHub (CodeBuild clones from there): push it first, or use --builder local"
  fi
  BID=$(aws codebuild start-build --project-name "$BUILD_PROJECT" --environment-variables-override \
        "name=DEPLOY_SHA,value=$SHA" "name=IMAGE_TAG,value=$TAG" "name=DOCKERFILE,value=$DOCKERFILE" \
        "name=MAVEN_MIRROR,value=$MIRROR" --query build.id --output text) || die 4 "could not start CodeBuild $BUILD_PROJECT"
  log "CodeBuild $BID: $REF ($SHA) -> $TAG"
  t0=$(date +%s)
  while :; do
    st=$(aws codebuild batch-get-builds --ids "$BID" --query 'builds[0].buildStatus' --output text)
    [ "$st" = IN_PROGRESS ] || break
    sleep 30
  done
  STREAM=$(aws codebuild batch-get-builds --ids "$BID" --query 'builds[0].logs.streamName' --output text)
  aws logs get-log-events --log-group-name "/aws/codebuild/$BUILD_PROJECT" --log-stream-name "$STREAM" --start-from-head \
    --query 'events[].message' --output text 2>/dev/null | tr '\t' '\n' > "$WORK/build.log" || true
  if [ "$st" != SUCCEEDED ]; then
    grep -E "What went wrong|429|ERROR|error:" -A3 "$WORK/build.log" | head -12 >&2 || true
    if grep -q " 429" "$WORK/build.log"; then echo "deploy: Maven Central answered 429; retry with --maven-mirror" >&2; fi
    die 4 "CodeBuild $st after $(( ($(date +%s)-t0)/60 )) min: aws logs tail /aws/codebuild/$BUILD_PROJECT --profile $PROFILE"
  fi
  log "built + pushed in CodeBuild in $(( ($(date +%s)-t0)/60 )) min; component commits in the image:"
  sed -n 's/^component: /    /p' "$WORK/build.log"
elif [ "$BUILDER" = local ]; then
  docker info >/dev/null 2>&1 || die 4 "docker is not running"
  BUILD_LOG="${TMPDIR:-/tmp}/darpan-deploy-$TAG.log"
  WT=$WORK/src
  git -C "$REPO_ROOT" worktree add --quiet --detach "$WT" "$SHA"
  log "building $REF ($SHA) -> $TAG  (log: $BUILD_LOG)"

  # Base from THIS checkout's aws/base.Dockerfile: older tags predate aws/.
  mkdir -p "$WORK/empty"
  docker build --quiet --platform linux/arm64 -f "$SCRIPT_DIR/base.Dockerfile" -t darpan-base:22.04 "$WORK/empty" >/dev/null \
    || die 4 "base image build failed"

  # Fresh component clones without rebuilding (and re-uploading) the OS/JDK layers: an ARG placed just
  # before the clone step changes every later RUN's cache key and nothing earlier. Falls back to --no-cache
  # if the clone step (the netrc secret mount) cannot be found.
  NOCACHE=
  if awk '/--mount=type=secret,id=netrc/ && !n { print "ARG DEPLOY_CACHEBUST"; n++ } { print }
          END { if (n != 1) exit 1 }' "$WT/$DOCKERFILE" > "$WT/Dockerfile.deploy"; then
    :
  else
    cp "$WT/$DOCKERFILE" "$WT/Dockerfile.deploy"; NOCACHE=--no-cache
    log "clone step not found: building with --no-cache"
  fi
  if [ "$MIRROR" = 1 ]; then
    cp "$SCRIPT_DIR/maven-mirror.init.gradle" "$WT/maven-mirror.init.gradle"
    awk '{ print } /^ENV GRADLE_USER_HOME=/ { print "COPY maven-mirror.init.gradle ${GRADLE_USER_HOME}/init.d/maven-mirror.gradle"; n++ }
         END { if (n != 1) exit 1 }' "$WT/Dockerfile.deploy" > "$WT/Dockerfile.mirror" \
      || die 4 "--maven-mirror: expected exactly one 'ENV GRADLE_USER_HOME=' line in $DOCKERFILE"
    mv "$WT/Dockerfile.mirror" "$WT/Dockerfile.deploy"
    log "Maven Central via Google's mirror"
  fi

  if ! docker build ${NOCACHE:+"$NOCACHE"} --platform linux/arm64 -f "$WT/Dockerfile.deploy" \
        --build-arg BASE_IMAGE=darpan-base:22.04 --build-arg DEPLOY_CACHEBUST="$TAG" \
        --label org.opencontainers.image.revision="$SHA" --label org.opencontainers.image.version="$REF" \
        -t "$REGISTRY/$ECR_REPO:$TAG" "$WT" > "$BUILD_LOG" 2>&1; then
    grep -E "What went wrong" -A4 "$BUILD_LOG" | head -8 >&2 || true
    if grep -q "429" "$BUILD_LOG"; then echo "deploy: Maven Central answered 429; retry with --maven-mirror" >&2; fi
    die 4 "image build failed (full log: $BUILD_LOG)"
  fi

  # Which component commits went in (the clones keep .git; best effort).
  log "component commits in the image:"
  docker run --rm --platform linux/arm64 --entrypoint sh "$REGISTRY/$ECR_REPO:$TAG" -c \
    'for d in /moqui-framework /moqui-framework/runtime /moqui-framework/runtime/component/*; do
       [ -d "$d/.git" ] && printf "    %-28s %s\n" "${d##*/}" "$(git -C "$d" log -1 --format="%h %cs %s" 2>/dev/null | cut -c1-70)"
     done' 2>/dev/null || echo "    (not readable from the image)"

  aws ecr get-login-password | docker login --username AWS --password-stdin "$REGISTRY" >/dev/null 2>&1 \
    || die 4 "ECR login failed"
  docker push --quiet "$REGISTRY/$ECR_REPO:$TAG" >/dev/null || die 4 "push failed"
  log "pushed $REGISTRY/$ECR_REPO:$TAG"
else
  die 2 "unknown --builder: $BUILDER (codebuild or local)"
fi
# Every path ends with the tag in ECR; check it (also catches a mistyped --tag).
aws ecr describe-images --repository-name "$ECR_REPO" --image-ids imageTag="$TAG" >/dev/null 2>&1 \
  || die 4 "tag $TAG is not in $ECR_REPO"

# ---------- change set: ImageTag (+ --set) on the existing template ----------
aws cloudformation describe-stacks --stack-name "$STACK" --query 'Stacks[0].Parameters[].ParameterKey' --output text \
  | tr '\t' '\n' > "$WORK/keys"
for kv in ${SETS[@]+"${SETS[@]}"}; do
  grep -qx "${kv%%=*}" "$WORK/keys" || die 2 "stack $STACK has no parameter ${kv%%=*}"
done
python3 -I - "$WORK/keys" "$TAG" ${SETS[@]+"${SETS[@]}"} > "$WORK/params.json" <<'PY'
import json, sys
keys = [k for k in open(sys.argv[1]).read().split() if k]
sets = dict(a.split("=", 1) for a in sys.argv[3:])
sets["ImageTag"] = sys.argv[2]
print(json.dumps([{"ParameterKey": k, "ParameterValue": sets[k]} if k in sets
                  else {"ParameterKey": k, "UsePreviousValue": True} for k in keys]))
PY

CS="deploy-$(date -u +%Y%m%d%H%M%S)"
# The deployer project sets DARPAN_CFN_ROLE_ARN (its StackUpdateRole): CloudFormation then applies the update as that
# role, which holds the reads a stack update resolves (task role ARNs, DB endpoint, the Database's secret reference) so
# the deployer's own role never does (DAR-OPS-010). Unset (a local run): CloudFormation uses the role the stack was
# last updated with, or the caller when it has none.
ROLE_ARGS=()
[ -n "${DARPAN_CFN_ROLE_ARN:-}" ] && ROLE_ARGS=(--role-arn "$DARPAN_CFN_ROLE_ARN")
aws cloudformation create-change-set --stack-name "$STACK" --change-set-name "$CS" --use-previous-template \
  --capabilities CAPABILITY_IAM --parameters "file://$WORK/params.json" ${ROLE_ARGS[@]+"${ROLE_ARGS[@]}"} >/dev/null
if ! aws cloudformation wait change-set-create-complete --stack-name "$STACK" --change-set-name "$CS" 2>/dev/null; then
  reason=$(aws cloudformation describe-change-set --stack-name "$STACK" --change-set-name "$CS" --query StatusReason --output text)
  aws cloudformation delete-change-set --stack-name "$STACK" --change-set-name "$CS" >/dev/null 2>&1 || true
  case "$reason" in *"didn't contain changes"*|*"No updates"*) log "nothing to change: $STACK already runs $TAG"; exit 0 ;; esac
  die 5 "change set failed: $reason"
fi

log "change set $CS on $STACK:"
aws cloudformation describe-change-set --stack-name "$STACK" --change-set-name "$CS" \
  --query 'Changes[].ResourceChange.[Action,LogicalResourceId,ResourceType,Replacement]' --output text \
  | tee "$WORK/changes" | sed 's/^/    /'
ALLOWED="TaskDefinition Service NoHealthyTaskAlarm TaskMemoryAlarm AlbSecurityGroup"
unexpected=$(awk -v ok=" $ALLOWED " 'index(ok, " " $2 " ") == 0 { print $2 }' "$WORK/changes")
if [ -n "$unexpected" ]; then
  aws cloudformation delete-change-set --stack-name "$STACK" --change-set-name "$CS" >/dev/null 2>&1 || true
  die 5 "change set would also touch: $(echo $unexpected) — infra changes need their own reviewed change set"
fi

if [ "$YES" != 1 ]; then
  aws cloudformation delete-change-set --stack-name "$STACK" --change-set-name "$CS" >/dev/null 2>&1 || true
  sets=""; for kv in ${SETS[@]+"${SETS[@]}"}; do sets="$sets --set $kv"; done
  echo
  echo "Plan only. To deploy: aws/deploy.sh $ENVNAME --tag $TAG$sets --yes"
  exit 6
fi

# ---------- execute + verify ----------
log "executing $CS (the running task is replaced in place: expect a few minutes of downtime)"
T0=$(( $(date +%s) * 1000 ))
aws cloudformation execute-change-set --stack-name "$STACK" --change-set-name "$CS"
if ! aws cloudformation wait stack-update-complete --stack-name "$STACK" 2>/dev/null; then
  aws cloudformation describe-events --stack-name "$STACK" --filters FailedEvents=true \
    --query 'OperationEvents[0:8].[LogicalResourceId,ResourceStatusReason]' --output text >&2 2>/dev/null || true
  die 7 "stack update did not complete ($(aws cloudformation describe-stacks --stack-name "$STACK" --query 'Stacks[0].StackStatus' --output text))"
fi
service_ids
DESIRED=$(aws ecs describe-services --cluster "$CLUSTER" --services "$SERVICE" --query 'services[0].desiredCount' --output text)
if [ "$DESIRED" = 0 ]; then log "deployed $TAG with DesiredCount 0: nothing running to check"; exit 0; fi
verify "$T0"
log "deployed: $STACK runs $TAG; $BASE/Login 200; boot data loaded without skipped files"
