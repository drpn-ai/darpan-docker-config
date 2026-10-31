# Script worker on AWS UAT (DAR-BE-169)

The Fargate counterpart of `k8s-lab/`. With `WorkerEnabled=true`, `darpan-uat.yaml` runs the tenant-script worker in
its own VPC and sets `DARPAN_SCRIPT_WORKER_URL=http://worker.<stack>.local:8090` on Moqui, so every tenant script runs
there and nowhere else (an unreachable worker returns a `WORKER` error; Moqui never falls back to running it).

| Wall | How |
|---|---|
| No internet, no Darpan network | Own VPC `10.41.0.0/16`: no internet gateway, no NAT; peered to UAT with a route only to Moqui's public subnets (`10.40.0.0/23`), so RDS / EFS / OpenSearch subnets have no route at all |
| Only Moqui gets in | Worker SG: `8090` only from Moqui's SG (peered-VPC SG reference), so not the ALB or anything else in the subnet |
| Only what Fargate needs goes out | Worker SG egress: `443` to the endpoint SG (ECR api, ECR dkr, Logs) and to the S3 prefix list |
| No exfiltration through the endpoints | Endpoint policies: ECR + Logs only for principals in this account (`aws:PrincipalAccount`); S3 only `s3:GetObject` on `prod-<region>-starport-layer-bucket` |
| No DNS exfiltration | Route 53 Resolver DNS Firewall on the worker VPC: the six endpoint names resolve, everything else is NXDOMAIN. It has to be its own VPC because DNS Firewall attaches to a whole VPC, and Moqui needs Shopify/NetSuite/OMS names |
| Nothing worth stealing | No task role (no AWS credentials), its own execution role (cannot read Moqui's secrets), no env from Moqui, uid 10001, read-only root, all capabilities dropped, no volumes, 384 MiB container cap |

Cost while on: ~$1/day (3 interface endpoints ~$0.72, the 0.25 vCPU worker ~$0.24). `WorkerEnabled=false` removes
every worker resource and the env var.

## Images

Root = UAT's image with only `darpan/script/ScriptSupervisor*` + `ScriptWorker*` swapped in its darpan jar (tag
`uat-worker`); worker = `k8s-lab/worker.Dockerfile` over a slim `darpan/script/**` jar (tag `script-worker-poc2`).
Both live in the stack's one ECR repo, so the worker exists before the service that pulls it (a new repo would be
empty at create time and trip the circuit breaker).

## Caller token (darpan 1950754)

Moqui sends `DARPAN_SCRIPT_WORKER_TOKEN` (from Secrets Manager) as `X-Darpan-Worker-Token`; the worker holds only
`DARPAN_SCRIPT_WORKER_TOKEN_SHA256` (plain env, a hash) and compares digests in constant time, answering 401 otherwise.
So the worker needs no secret, no Secrets Manager endpoint and no extra DNS name, and an escaped script that reads the
worker's environment learns nothing it can call the worker with. Where NetworkPolicy is not enforced (a cluster
without a policy-enforcing CNI) this is the only wall. The secret lives outside the stack because CloudFormation
cannot hash a value it generates. Turning it on (secret created by a person, not by an agent):

```sh
T=$(openssl rand -base64 36 | tr -d '/+=\n')
printf %s "$T" | aws secretsmanager create-secret --profile darpan --region us-east-2 \
  --name darpan-uat/script-worker-token --secret-string file:///dev/stdin --query ARN --output text
printf %s "$T" | shasum -a 256 | cut -d' ' -f1; unset T
# then a change set: ImageTag=uat-worker2 WorkerImageTag=script-worker-poc3
#   WorkerTokenSecretArn=<ARN above> WorkerTokenSha256=<hash above>   (Moqui restarts once)
```

With the token on, `worker-guardrail-check.sh` checks that a call without it gets 401 (the probe never holds the
token: it would land in ECS task overrides); `1 + 1` and the escape then run through Moqui's `run#TenantScript`.

## Re-check the walls

```sh
aws/worker-guardrail-check.sh   # ~2 min, three probe tasks; exit 0 only when every check is PASS
```

ECS overrides cannot change `entryPoint`, so the check clones the LIVE worker task definition (same uid, read-only
root, capabilities, memory cap, no task role), swaps only the entrypoint for `aws/worker-probe.sh`, runs it from three
positions (worker; Moqui's subnet + SG as the control; Moqui's VPC with the ALB's SG as "not Moqui"), pairs the answers
and deregisters the clone. A wall the control cannot cross either reads INCONCLUSIVE, never PASS.

## What was proven (2026-10-31)

- 19/19 on `darpan-uat`, twice, including once against a worker that had served nothing (first-call `1 + 1` = 2).
- From the worker: MySQL, OpenSearch, the internet (by IP and by name), DNS for any other name, Moqui's own :8080 and
  instance metadata are all unreachable, while the control reaches each. The ALB's SG and a worker-VPC neighbour are
  refused on 8090 while Moqui's SG connects. ECR resolves to the endpoint's 10.41.x address.
- DNS Firewall works on the Free plan (the only unknown going in).

## Learned

- Fargate pulls the image and ships logs through the task's own ENI: a worker with no egress at all cannot start.
- 0.25 vCPU: a fresh JVM's first JEXL evaluation ran past EXPRESSION's 250 ms. `ScriptWorker.main` now warms each
  profile before the port opens; ready in ~11 s, and the health check (hence Cloud Map) never shows a cold worker.
- A Fargate bind-mount volume is root-owned and not writable by a non-root uid; the worker needs none.
- S3 answers `NoSuchBucket` before evaluating any policy, so a live "write to a foreign bucket" test needs a real
  bucket that grants access; the S3 endpoint policy is checked statically instead.
- Fargate offers no `no-new-privileges` switch; uid 10001 + no capabilities is the wall (reported as info).

## Gaps before prod

- Caller token built and image-tested (no/wrong token 401, right token runs) but NOT on UAT until the secret exists.
- One worker JVM serves every tenant: an escape could see another tenant's in-flight input; per-tenant workers or a
  process per evaluation close it.
- Moqui's real path (`run#TenantScript` with a login) and "worker down → WORKER, never local" not yet exercised on AWS.
- No live S3 exfiltration test (see Learned); no deliberate wall-removal (mutation) run on AWS yet.
- Images hand-built; base image carries curl/wget/perl/bash (distroless removes the toolkit, but the probe needs a shell).
