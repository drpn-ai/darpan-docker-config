# DAR-BE-169. Runs INSIDE a probe task (a clone of the script worker's task definition with only the entrypoint
# changed) from one of three network positions; worker-guardrail-check.sh pairs the answers up. Prints one line per
# attempt: "R <name> 0" = it worked, "R <name> 1" = it did not. Never prints values, only names and short replies.
tcp() { timeout 4 bash -c "exec 3<>/dev/tcp/$1/$2" 2>/dev/null; }
r() { local n=$1; shift; if "$@" >/dev/null 2>&1; then echo "R $n 0"; else echo "R $n 1"; fi; }
ecr_private() { getent hosts "api.ecr.$AWS_REGION_NAME.amazonaws.com" | grep -q '^10\.41\.'; }
not_root() { [ "$(id -u)" != 0 ]; }
no_caps() { grep -q '^CapEff:[[:space:]]*0000000000000000$' /proc/self/status; }
no_new_privs() { grep -q '^NoNewPrivs:[[:space:]]*1$' /proc/self/status; }
SECRET_NAMES='pass|secret|token|jwt|crypt|_key$|^Moqui_DB|^DB_|^elasticsearch'
ro_root() { awk '$2=="/" {print $4}' /proc/mounts | tail -1 | grep -q -E '^ro(,|$)'; }
no_secret_env() { ! env | cut -d= -f1 | grep -E -i "$SECRET_NAMES"; }
no_aws_creds() { [ -z "${AWS_CONTAINER_CREDENTIALS_RELATIVE_URI:-}" ] && [ -z "${AWS_ACCESS_KEY_ID:-}" ] \
  && ! curl -sf -m 3 "http://169.254.170.2/v2/credentials/" >/dev/null; }
mem_cap() { local m; m=$(cat /sys/fs/cgroup/memory.max 2>/dev/null || cat /sys/fs/cgroup/memory/memory.limit_in_bytes); \
  echo "M $m"; [ "$m" != max ] && [ "$m" -le "$MEM_MAX_BYTES" ]; }

echo "P $PROBE_POSITION"
r mysql        tcp "$MYSQL_IP" 3306
r search       tcp "$SEARCH_IP" 443
r inet_ip      tcp 1.1.1.1 443
r inet_https   curl -sS -m 6 -o /dev/null https://example.com
r dns_ext      timeout 6 getent hosts example.com
r root_http    tcp "$ROOT_IP" 8080
r worker_tcp   tcp "$WORKER_IP" 8090
r imds         tcp 169.254.169.254 80
r ecr_private  ecr_private
r not_root     not_root
r no_caps      no_caps
r no_new_privs no_new_privs
r ro_root      ro_root
r no_secret_env no_secret_env
r no_aws_creds no_aws_creds
r mem_cap      mem_cap
mem_cap | grep '^M ' || true
echo "E $(env | cut -d= -f1 | grep -E -i "$SECRET_NAMES" | tr '\n' ' ')"
echo "W $(find / -xdev \( -path /proc -o -path /sys \) -prune -o -writable -print 2>/dev/null | head -5 | tr '\n' ' ')"
echo "F one $(curl -s -m 10 -H 'Content-Type: application/json' --data-binary "$ONE_JSON" "$WORKER_URL/evaluate" | head -c 300)"
echo "F esc $(curl -s -m 10 -H 'Content-Type: application/json' --data-binary "$ESC_JSON" "$WORKER_URL/evaluate" | head -c 300)"
echo "END"
sleep 5
