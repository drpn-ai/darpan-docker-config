#!/bin/bash

set -e

# Audit 2026-06-11 #12/#14: fail fast if required production secrets are unset, instead of silently
# keeping the moqui/moqui datasource defaults or falling back to Moqui's published default entity
# crypt pass (which would encrypt every tenant's stored secrets/tokens under a publicly known
# constant). entity_ds_crypt_pass is exported so Moqui's ${entity_ds_crypt_pass} placeholder resolves.
# Audit 2026-06-27 MACH P1 #2: JWT_KEY added to the fail-fast set. A container that boots without a
# real JWT signing key would silently use an empty/insecure default, making all issued tokens trivially
# forgeable. Fail hard here so the misconfiguration surfaces at deploy time, not in production traffic.
: "${Moqui_DB_HOST:?Moqui_DB_HOST must be set for production}"
: "${Moqui_DB_USER:?Moqui_DB_USER must be set for production}"
: "${Moqui_DB_PASSWORD:?Moqui_DB_PASSWORD must be set for production}"
: "${Moqui_DB_NAME:?Moqui_DB_NAME must be set for production}"
: "${entity_ds_crypt_pass:?entity_ds_crypt_pass must be set to a deployment-unique secret}"
: "${JWT_KEY:?JWT_KEY must be set to a strong, deployment-unique signing secret}"
export entity_ds_crypt_pass
# MACH Security P1 (crypt-key rotation): entity_ds_crypt_pass_old is OPTIONAL — only set during a
# rotation window. When unset, MoquiProductionConf.xml defaults it to entity_ds_crypt_pass so the
# decrypt-alt entries are a no-op. Export it unconditionally so the shell default in the conf
# placeholder resolves correctly whether or not the caller set it.
export entity_ds_crypt_pass_old="${entity_ds_crypt_pass_old:-$entity_ds_crypt_pass}"
# Export JWT_KEY so Moqui's ${JWT_KEY} placeholder in MoquiProductionConf.xml resolves at runtime.
export JWT_KEY

# Fix 2026-06-29: switched from '/' delimiter + '$VAR' single-quote splicing to '|' delimiter +
# double-quoted expansion so credentials containing '/' or "'" (common from secrets managers)
# no longer crash the entrypoint under set -e.
sed -i 's|name="entity_ds_host" value="127.0.0.1"|name="entity_ds_host" value="'"$Moqui_DB_HOST"'"|g' "$CONF_FILE"
sed -i 's|name="webapp_http_host" value=""|name="webapp_http_host" value="'"$Moqui_HOST"'"|g' "$CONF_FILE"

sed -i 's|name="entity_ds_user" value="moqui"|name="entity_ds_user" value="'"$Moqui_DB_USER"'"|g' "$CONF_FILE"
sed -i 's|name="entity_ds_password" value="moqui"|name="entity_ds_password" value="'"$Moqui_DB_PASSWORD"'"|g' "$CONF_FILE"
sed -i 's|name="entity_ds_database" value="moqui"|name="entity_ds_database" value="'"$Moqui_DB_NAME"'"|g' "$CONF_FILE"

WEBAPP_ALLOW_ORIGINS_OVERRIDE="${Moqui_WEBAPP_ALLOW_ORIGINS:-${WEBAPP_ALLOW_ORIGINS:-}}"
if [ -n "$WEBAPP_ALLOW_ORIGINS_OVERRIDE" ]; then
  sed -i 's|name="webapp_allow_origins" value="[^"]*"|name="webapp_allow_origins" value="'"$WEBAPP_ALLOW_ORIGINS_OVERRIDE"'"|g' "$CONF_FILE"
fi

# Timezone setting
sed -i 's|name="default_time_zone" value=""|name="default_time_zone" value="'"$TIME_ZONE"'"|g' "$CONF_FILE"
sed -i 's|name="database_time_zone" value=""|name="database_time_zone" value="'"$TIME_ZONE"'"|g' "$CONF_FILE"

# JDK 21 runtime flags. The --add-opens set is the canonical Spark 3.5.x JDK 17+/21 list
# (Spark's own JavaModuleOptions); without it Spark SQL fails on sun.nio.ch.DirectBuffer at
# SparkContext init. -XX:+EnableDynamicAgentLoading suppresses the ByteBuddy/Mockito agent
# warning. --enable-native-access=ALL-UNNAMED quiets Netty/OpenSearch native-access warnings.
export JAVA_TOOL_OPTIONS="${JAVA_TOOL_OPTIONS:+$JAVA_TOOL_OPTIONS }\
--add-opens=java.base/java.lang=ALL-UNNAMED \
--add-opens=java.base/java.lang.invoke=ALL-UNNAMED \
--add-opens=java.base/java.lang.reflect=ALL-UNNAMED \
--add-opens=java.base/java.io=ALL-UNNAMED \
--add-opens=java.base/java.net=ALL-UNNAMED \
--add-opens=java.base/java.nio=ALL-UNNAMED \
--add-opens=java.base/java.util=ALL-UNNAMED \
--add-opens=java.base/java.util.concurrent=ALL-UNNAMED \
--add-opens=java.base/java.util.concurrent.atomic=ALL-UNNAMED \
--add-opens=java.base/sun.nio.ch=ALL-UNNAMED \
--add-opens=java.base/sun.nio.cs=ALL-UNNAMED \
--add-opens=java.base/sun.security.action=ALL-UNNAMED \
--add-opens=java.base/sun.util.calendar=ALL-UNNAMED \
--add-opens=java.security.jgss/sun.security.krb5=ALL-UNNAMED \
-XX:+EnableDynamicAgentLoading \
--enable-native-access=ALL-UNNAMED"

$SLEEP

# MACH P1 Item 3 — build / release / run separation (12-factor principle):
#
# The upgrade-data load (loadDarpanUpgradeData) is a RELEASE step, not a RUN step.
# For routine container starts (scaling, restarts, rolling restarts) set:
#
#   DARPAN_LOAD_UPGRADE_DATA=N
#
# This makes container start fast and idempotent with zero side effects on the database.
# Run the load exactly ONCE per release, before the new pods/tasks come up:
#
#   docker run --rm -e DARPAN_LOAD_UPGRADE_DATA=Y \
#              -e Moqui_DB_HOST=... -e entity_ds_crypt_pass=... -e JWT_KEY=... \
#              <image> /moqui-framework/gradlew --no-daemon \
#              :runtime:component:darpan:loadDarpanUpgradeData -PmoquiConf=$CONF_FILE ...
#
# or as a Kubernetes init-container / ECS run-task / CI deploy step.
# The default (Y) is deliberately preserved so the first deployment of a new image is
# safe out-of-the-box; only suppress it once the deploy pipeline runs the load separately.
if [ "${DARPAN_LOAD_UPGRADE_DATA:-Y}" != "N" ]; then
  echo "Loading Darpan upgrade data"
  DARPAN_MOQUI_FRAMEWORK_DIR="${DARPAN_MOQUI_FRAMEWORK_DIR:-/moqui-framework}"
  # Fix 2026-07-02: Gradle 9 removed -b/--build-file ("Unknown command-line option '-b'"), so the
  # component task can no longer be run standalone against its build file. The framework
  # settings.gradle already includes every runtime component as a subproject, so invoke the task by
  # its qualified project path instead (same convention as :runtime:component:darpan:test).
  DARPAN_UPGRADE_DATA_TASK="${DARPAN_UPGRADE_DATA_TASK:-:runtime:component:darpan:loadDarpanUpgradeData}"
  DARPAN_GRADLEW="${DARPAN_GRADLEW:-$DARPAN_MOQUI_FRAMEWORK_DIR/gradlew}"
  DARPAN_UPGRADE_DATA_TYPES="${DARPAN_UPGRADE_DATA_TYPES:-darpan-seed}"
  DARPAN_UPGRADE_DATA_LOCATION="${DARPAN_UPGRADE_DATA_LOCATION:-component://darpan/data/upgrade-data.xml}"
  load_args=(
    --no-daemon
    "$DARPAN_UPGRADE_DATA_TASK"
    "-PmoquiConf=$CONF_FILE"
    "-PmoquiRuntime=$DARPAN_MOQUI_FRAMEWORK_DIR/runtime"
    "-PmoquiWar=$DARPAN_MOQUI_FRAMEWORK_DIR/moqui-plus-runtime.war"
    "-Ptypes=$DARPAN_UPGRADE_DATA_TYPES"
    "-PupgradeDataLocation=$DARPAN_UPGRADE_DATA_LOCATION"
  )
  if [ -n "${DARPAN_UPGRADE_DATA_LOAD_ARGS:-}" ]; then
    load_args+=("-PextraLoadArgs=$DARPAN_UPGRADE_DATA_LOAD_ARGS")
  fi
  (cd "$DARPAN_MOQUI_FRAMEWORK_DIR" && "$DARPAN_GRADLEW" "${load_args[@]}")
fi

# Audit 2026-06-26 MACH P0 #1: run the JVM as PID 1 (exec) so SIGTERM/SIGINT from `docker stop` or an
# orchestrator reaches MoquiStart's shutdown hook (MoquiShutdown, MoquiStart.java:86) for an orderly
# framework destroy + clean Bitronix XA flush. Previously the JVM ran detached under `screen` while
# `tail -F` held PID 1, so the signal never reached the JVM (hard SIGKILL after the grace period →
# in-flight reconciliation XA transactions lost) and any container restart policy was structurally
# unreachable. Moqui already streams logs to container stdout via the log4j2 STDOUT console appender,
# so the explicit tail is no longer required.
exec java $JAVA_OPTS -cp . MoquiStart port=8080 conf=$CONF_FILE
