# Root + script-worker pods (DAR-BE-169 lab)

A local kind cluster where Darpan's root pod (Moqui, DB credentials, tenant tokens) sends every tenant script to a
separate worker pod that holds nothing worth stealing and can reach nothing.

| Namespace | Pods | Walls |
|---|---|---|
| `darpan-lab` | `darpan-root`, `mysql` | none added (today's posture) |
| `darpan-scripts` | `script-worker` | Pod Security `restricted` enforced; default-deny ingress+egress; ingress on 8090 only from `app=darpan-root`; uid 10001, read-only root fs, all capabilities dropped, no service-account token, 384Mi memory cap |

The switch is one env var on the root: `DARPAN_SCRIPT_WORKER_URL`. Unset, scripts run in Moqui as before. Set, they run
only in the worker; an unreachable worker returns a `WORKER` error and the script is not run anywhere else.

## Build and run

```sh
# 1. Images. darpan:uat is the normal image (docker/Dockerfile). The lab jars are the darpan jar from that image with
#    darpan/script/ScriptSupervisor*.class + ScriptWorker*.class replaced from a local build
#    (./gradlew :runtime:component:darpan:compileGroovy), plus a slim jar of only darpan/script/**.
docker build -f k8s-lab/worker.Dockerfile -t darpan-script-worker:lab <dir with darpan-script-engine.jar>
docker build -f k8s-lab/root.Dockerfile   -t darpan-root:lab          <dir with darpan-2.1.5-lab.jar>

# 2. Cluster
kind create cluster --name darpan-lab
kind load docker-image darpan-script-worker:lab darpan-root:lab --name darpan-lab
kubectl apply -f k8s-lab/lab.yaml
kubectl -n darpan-lab create secret generic darpan-secrets \
  --from-literal=db-password="$(openssl rand -hex 20)" --from-literal=db-root-password="$(openssl rand -hex 20)" \
  --from-literal=crypt-pass="$(openssl rand -hex 24)" --from-literal=jwt-key="$(openssl rand -hex 32)"

# 3. Tear down
kind delete cluster --name darpan-lab
```

## Re-check the walls

```sh
k8s-lab/guardrail-check.sh   # ~35 s; exit 0 only when every check is PASS
```

17 checks: 6 egress walls (MySQL, internet, DNS lookup, cluster DNS, Kubernetes API, cloud metadata), 1 ingress
wall, 8 identity checks (uid, capabilities, no-new-privileges, read-only root, /tmp writable, no service-account
token, no secret-looking env names, memory cap), and 2 function checks posted from the root pod (`1 + 1` runs, the
`forName('java.lang.Runtime')` escape comes back `NOT_ALLOWED`). Each network wall is paired with a control pod that
must reach the same target; if it cannot, the wall reports INCONCLUSIVE instead of PASS. Proven not hollow
(2026-10-31): with `default-deny` deleted the five egress walls report FAIL and the script exits 1.

## What was proven (2026-10-31)

- Root -> worker through `ScriptSupervisor.evaluate` (the method both Darpan callers use): result returned; a
  `forName("java.lang.Runtime")` attempt comes back `NOT_ALLOWED`.
- From inside the worker: MySQL, the internet, cluster DNS and the Kubernetes API are all unreachable; control pod in
  `darpan-lab` reaches MySQL and the internet, and is refused by the worker.
- 8 concurrent max-size inputs (~2 MB, 499k values each) at 384Mi: all served, no restart (4 server threads x
  per-request input caps bound the worker's memory).
- Same flood at 160Mi: worker `OOMKilled` (exit 137) and restarted; root's dispatcher returned `WORKER`, units 0,
  "the script was not run"; root Moqui kept serving, 0 restarts.

## Learned

- MySQL 8: Darpan's DB user needs `XA_RECOVER_ADMIN` (Bitronix runs `XA RECOVER` at startup; without it
  `XAER_RMERR`). RDS's master user has it; the lab grants it via the `mysql-init` ConfigMap.
- JEXL logs through commons-logging; the worker image must carry it (Moqui supplies it in the root).
- At small memory caps the kernel kills the container before the JVM's own OutOfMemoryError handling; keep the cap
  well above heap (MaxRAMPercentage 70 at 384Mi held).
