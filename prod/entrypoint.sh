#!/bin/bash
set -e

echo "========================================="
echo " Chelan Darpan — Starting Moqui"
echo "========================================="

cd /moqui-deploy

# Fail fast if required production secrets are unset (audit 2026-06-11 #12/#14, MACH P1 #2):
# booting with the moqui/moqui datasource defaults, Moqui's published default entity crypt pass,
# or an empty JWT signing key must surface at deploy time, not in production traffic.
: "${DB_HOST:?DB_HOST must be set for production}"
: "${DB_USER:?DB_USER must be set for production}"
: "${DB_PASSWORD:?DB_PASSWORD must be set for production}"
: "${DB_NAME:?DB_NAME must be set for production}"
: "${entity_ds_crypt_pass:?entity_ds_crypt_pass must be set to a deployment-unique secret}"
: "${JWT_KEY:?JWT_KEY must be set to a strong, deployment-unique signing secret}"
DB_PORT="${DB_PORT:-5432}"
export entity_ds_crypt_pass
# Crypt-key rotation: entity_ds_crypt_pass_old is OPTIONAL — only set during a rotation window.
# Export it unconditionally so the conf placeholder resolves whether or not the caller set it.
export entity_ds_crypt_pass_old="${entity_ds_crypt_pass_old:-$entity_ds_crypt_pass}"
export JWT_KEY

echo "--- Applying DB configuration..."
# '|' delimiter + double-quoted expansion so credentials containing '/' or "'" (common from
# secrets managers) do not crash the entrypoint under set -e. Chelan is Postgres — the conf's
# datasource is PGXADataSource and the placeholder port is 5432.
sed -i 's|name="entity_ds_host" value="127.0.0.1"|name="entity_ds_host" value="'"$DB_HOST"'"|g' "$CONF_FILE"
sed -i 's|name="entity_ds_port" value="5432"|name="entity_ds_port" value="'"$DB_PORT"'"|g' "$CONF_FILE"
sed -i 's|name="entity_ds_user" value="moqui"|name="entity_ds_user" value="'"$DB_USER"'"|g' "$CONF_FILE"
sed -i 's|name="entity_ds_password" value="moqui"|name="entity_ds_password" value="'"$DB_PASSWORD"'"|g' "$CONF_FILE"
sed -i 's|name="entity_ds_database" value="moqui"|name="entity_ds_database" value="'"$DB_NAME"'"|g' "$CONF_FILE"

echo "--- Applying URL/Host configuration..."
sed -i 's|name="webapp_http_host" value=""|name="webapp_http_host" value="'"$HC_HOST"'"|g' "$CONF_FILE"
WEBAPP_ALLOW_ORIGINS_OVERRIDE="${WEBAPP_ALLOW_ORIGINS:-}"
if [ -n "$WEBAPP_ALLOW_ORIGINS_OVERRIDE" ]; then
  sed -i 's|name="webapp_allow_origins" value="[^"]*"|name="webapp_allow_origins" value="'"$WEBAPP_ALLOW_ORIGINS_OVERRIDE"'"|g' "$CONF_FILE"
fi

echo "--- Applying timezone configuration..."
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

echo "--- Configuration applied successfully"

sleep $SLEEP

# Upgrade-data load is a RELEASE step, not a RUN step (12-factor). Default Y so a first deploy
# is safe out-of-the-box; set DARPAN_LOAD_UPGRADE_DATA=N once the deploy pipeline runs the load
# separately (init-container / run-task / CI step), making container start fast and idempotent.
if [ "${DARPAN_LOAD_UPGRADE_DATA:-Y}" != "N" ]; then
  echo "--- Ensuring Darpan seed/reference data present (idempotent darpan-seed load)..."
  DARPAN_MOQUI_FRAMEWORK_DIR="${DARPAN_MOQUI_FRAMEWORK_DIR:-/moqui-framework}"
  # Gradle 9 removed -b/--build-file; invoke the component task by its qualified project path.
  DARPAN_UPGRADE_DATA_TASK="${DARPAN_UPGRADE_DATA_TASK:-:runtime:component:darpan:loadDarpanUpgradeData}"
  DARPAN_GRADLEW="${DARPAN_GRADLEW:-$DARPAN_MOQUI_FRAMEWORK_DIR/gradlew}"
  DARPAN_UPGRADE_DATA_TYPES="${DARPAN_UPGRADE_DATA_TYPES:-darpan-seed}"
  # Load ALL darpan-seed files by type (a Moqui data load is an upsert — only missing records are
  # inserted). Test/UAT data uses type "darpan-fixture" and is excluded. Set
  # DARPAN_UPGRADE_DATA_LOCATION only to force a single file.
  DARPAN_UPGRADE_DATA_LOCATION="${DARPAN_UPGRADE_DATA_LOCATION:-}"
  load_args=(
    --no-daemon
    "$DARPAN_UPGRADE_DATA_TASK"
    "-PmoquiConf=$CONF_FILE"
    "-PmoquiRuntime=$DARPAN_MOQUI_FRAMEWORK_DIR/runtime"
    "-PmoquiWar=$DARPAN_MOQUI_FRAMEWORK_DIR/moqui-plus-runtime.war"
    "-Ptypes=$DARPAN_UPGRADE_DATA_TYPES"
  )
  if [ -n "$DARPAN_UPGRADE_DATA_LOCATION" ]; then
    load_args+=("-PupgradeDataLocation=$DARPAN_UPGRADE_DATA_LOCATION")
  fi
  if [ -n "${DARPAN_UPGRADE_DATA_LOAD_ARGS:-}" ]; then
    load_args+=("-PextraLoadArgs=$DARPAN_UPGRADE_DATA_LOAD_ARGS")
  fi
  (cd "$DARPAN_MOQUI_FRAMEWORK_DIR" && "$DARPAN_GRADLEW" "${load_args[@]}")
fi

# exec so the JVM runs as PID 1: SIGTERM from `docker stop` / the orchestrator reaches
# MoquiStart's shutdown hook for an orderly framework destroy + clean Bitronix XA flush.
exec java $JAVA_OPTS -cp . MoquiStart port=8080 conf=$CONF_FILE
