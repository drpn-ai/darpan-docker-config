# Docker-first Darpan/Moqui image — `chelan` branch. Chelan deploys build from THIS branch.
#
# Modeled on the classic OFBiz single-stage Dockerfile: plain build args, .netrc for private
# clones, tunable heap via JAVA_MIN/JAVA_MAX, simple ENV defaults, one EXPOSEd port, and an
# entrypoint COPY'd from the build context. Intended for `docker build` + `docker run` /
# docker compose directly — no BuildKit secrets, no digest-pin enforcement, no orchestrator
# assumptions.
#
# Build from the repo root (the entrypoint and conf files are copied from the context):
#   docker build \
#     --build-arg GIT_USERNAME=<user> --build-arg GIT_PASSWORD=<token> \
#     -t darpan:chelan .
#
# NOTE: unlike the BuildKit-secret build, GIT_USERNAME/GIT_PASSWORD are visible in
# `docker history`. Use a short-lived, read-only token and treat the image as private.

# eclipse-temurin:21-jdk (Ubuntu) — Moqui 4, Gradle 9, and Spark 3.5 all require JDK 21.
FROM eclipse-temurin:21-jdk

ARG GIT_USERNAME=
ARG GIT_PASSWORD=
# JVM heap for the runtime JVM (MoquiStart). Fixed sizes, OFBiz-style — no cgroup percentages.
ARG JAVA_MIN=1024m
ARG JAVA_MAX=4096m

# Source refs. moqui-framework is pinned to v4.0.0 + PR #705 (embedded Bitronix — the v4.0.0
# tag predates that merge); moqui-runtime v3.9.9 is the dev baseline. Product components
# default to main; override with release tags for a production build.
ARG MOQUI_FRAMEWORK_REF=d12a86e1ac735ae41d93b586bbcb789889997110
ARG MOQUI_RUNTIME_REF=v3.9.9
ARG MOQUI_SFTP_REF=v1.0.3
ARG DARPAN_REF=main
ARG DARPAN_HOTWAX_REF=main
ARG SHOPIFY_DARPAN_REF=main
ARG NETSUITE_DARPAN_REF=main
ARG MOQUI_GQL_REF=main

RUN apt-get update && apt-get install -y --no-install-recommends git curl \
    && rm -rf /var/lib/apt/lists/*

# Store git credentials for private repo access
RUN printf 'machine github.com\nlogin %s\npassword %s\n' "${GIT_USERNAME}" "${GIT_PASSWORD}" > /root/.netrc \
    && chmod 600 /root/.netrc

# Clone the framework at its pinned commit (git clone -b only takes branches/tags, so
# fetch-by-sha), then the runtime and components into place.
RUN git init /moqui-framework \
    && git -C /moqui-framework remote add origin https://github.com/moqui/moqui-framework.git \
    && git -C /moqui-framework fetch --depth 1 origin "${MOQUI_FRAMEWORK_REF}" \
    && git -C /moqui-framework checkout --detach FETCH_HEAD

RUN git clone --depth 1 -b "${MOQUI_RUNTIME_REF}"   https://github.com/moqui/moqui-runtime.git    /moqui-framework/runtime
WORKDIR /moqui-framework/runtime/component
RUN git clone --depth 1 -b "${MOQUI_SFTP_REF}"      https://github.com/moqui/moqui-sftp.git
RUN git clone --depth 1 -b "${DARPAN_REF}"          https://github.com/drpn-ai/darpan.git
RUN git clone --depth 1 -b "${DARPAN_HOTWAX_REF}"   https://github.com/drpn-ai/darpan-hotwax.git
RUN git clone --depth 1 -b "${SHOPIFY_DARPAN_REF}"  https://github.com/drpn-ai/shopify-darpan.git
RUN git clone --depth 1 -b "${NETSUITE_DARPAN_REF}" https://github.com/drpn-ai/netsuite-darpan.git
RUN git clone --depth 1 -b "${MOQUI_GQL_REF}"       https://github.com/drpn-ai/moqui-gql.git

# Remove git credentials from image filesystem (the ARG values remain in build metadata —
# see the header note; use a disposable token)
RUN rm -f /root/.netrc

WORKDIR /moqui-framework

# Production conf + framework build.gradle patch come from THIS repo (the build context),
# not from the cloned component — this repo is the source of truth for docker config.
COPY ./MoquiProductionConf.xml runtime/conf/MoquiProductionConf.xml
COPY ./buildGradle.patch buildGradle.patch

# Cross-site cookie policy: swap the SameSite marker to NONE (UI is served from a different
# origin than the API). Fail the build if the upstream marker disappears rather than
# silently downgrading cookie policy.
RUN grep -q '__SAME_SITE_LAX__' framework/src/main/webapp/WEB-INF/web.xml \
    && sed -i 's/__SAME_SITE_LAX__/__SAME_SITE_NONE__/g' framework/src/main/webapp/WEB-INF/web.xml

# Framework build.gradle patch: Spark --add-exports for JDK 21 + append-form jvmArgs.
# Dry-run first so ref drift fails loudly instead of with a cryptic line-number error.
RUN git apply --check buildGradle.patch \
    || { echo "ERROR: buildGradle.patch no longer applies to moqui-framework @ ${MOQUI_FRAMEWORK_REF}; regenerate it." >&2; exit 1; }
RUN git apply buildGradle.patch

# Build. moqui-gql's engine jar must be built FIRST (it contributes a GqlToolFactory loaded
# at ECF init and vendors graphql-java); addRuntime alone would not build it.
ENV GRADLE_USER_HOME=/moqui-framework/.gradle
RUN ./gradlew --no-daemon :runtime:component:moqui-gql:jar addRuntime

# Extract the war so the entrypoint can `exec java -cp . MoquiStart` as PID 1.
WORKDIR /moqui-deploy
RUN jar -xf /moqui-framework/moqui-plus-runtime.war

# Copy entrypoint script (from the build context — same entrypoint as the k8s-track image:
# fail-fast secret gate, conf templating, Spark --add-opens, optional upgrade-data load)
COPY ./entrypoint.sh /moqui-deploy/entrypoint.sh
RUN chmod +x /moqui-deploy/entrypoint.sh

ENV JAVA_OPTS="-Xms${JAVA_MIN} -Xmx${JAVA_MAX} -XX:+HeapDumpOnOutOfMemoryError -XX:HeapDumpPath=/moqui-framework/runtime/log/"
ENV CONF_FILE="/moqui-framework/runtime/conf/MoquiProductionConf.xml"
ENV SLEEP="sleep 5"

# Required at runtime (the entrypoint fails fast if the secrets are unset):
#   Moqui_DB_HOST / Moqui_DB_USER / Moqui_DB_PASSWORD / Moqui_DB_NAME
#   entity_ds_crypt_pass, JWT_KEY
# Optional: MOQUI_HOST, WEBAPP_ALLOW_ORIGINS, ELASTICSEARCH_HOST, TIME_ZONE,
#   DARPAN_LOAD_UPGRADE_DATA=N to skip the per-boot seed/upgrade data load.
ENV JWT_KEY=
ENV MOQUI_HOST=
ENV Moqui_DB_HOST=
ENV Moqui_DB_USER=
ENV Moqui_DB_PASSWORD=
ENV Moqui_DB_NAME=
ENV WEBAPP_ALLOW_ORIGINS=
ENV ELASTICSEARCH_HOST=
ENV TIME_ZONE=

EXPOSE 8080

# /status is bound to 127.0.0.1 and excluded from server-stats; start-period covers JVM boot
# plus the per-boot upgrade-data load.
HEALTHCHECK --interval=30s --timeout=10s --start-period=300s --retries=3 \
    CMD curl -fsS http://127.0.0.1:8080/status || exit 1

ENTRYPOINT ["/moqui-deploy/entrypoint.sh"]
