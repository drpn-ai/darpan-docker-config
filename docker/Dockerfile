# syntax=docker/dockerfile:1.6
#
# Audit Wave 5 hardening:
#  - W5 #36 / 2026-06-11 #24: base image was a mutable `:latest` tag (non-reproducible). Operators
#    MUST override BASE_IMAGE in CI/prod with a digest-pinned reference (`maarg-base-os@sha256:<d>`).
#    A digest REQUIRES the `@` separator — a `:sha256:...` tag form is an invalid Docker reference —
#    so BASE_IMAGE is a full reference, not a bare tag/digest value. Set
#    `--build-arg REQUIRE_PINNED_BASE=1` in CI/prod to FAIL the build unless BASE_IMAGE is
#    digest-pinned. The default names the latest tag for dev convenience.
#  - W5 #37: GitHub credentials are now BuildKit `--mount=type=secret` (above `RUN`), so they
#    NEVER land in an image layer. ARG GIT_USERNAME/GIT_PASSWORD remain for backward compat
#    during the rollout window; once CI is on `--secret id=netrc,...` they can be dropped.
#  - W5 #38: Moqui framework / runtime / sftp refs are pinned in-file to stable immutable refs
#    matching the dev baseline (see the ARG block); no build-arg override is required. Product
#    components (darpan / darpan-hotwax / shopify-darpan / netsuite-darpan / database-darpan) default
#    to `main` on this UAT-track image by design; `prod/Dockerfile` pins them to release tags.
ARG BASE_IMAGE=public.ecr.aws/j6s7y7u4/hotwax/ubuntu:22.04

# JDK 21 provider stage. The default base ships no JDK 21 (maarg-base-os had JDK 11), but Moqui 4, the upstream
# framework's Gradle 9 (refuses to RUN on < JVM 17), and Spark 3.5 all require JDK 21. Copy a
# self-contained Temurin 21 (Ubuntu/glibc — ABI-compatible with the 22.04 base) instead of depending
# on the base image's apt sources. eclipse-temurin:21-jdk is the same JDK image docker/simple uses.
FROM eclipse-temurin:21-jdk AS jdk21

FROM ${BASE_IMAGE}

# Audit 2026-06-11 #24 (+ self-review): the default BASE_IMAGE is a mutable tag, so a CI/prod build
# that forgets a digest pin silently produces a non-reproducible image. Set REQUIRE_PINNED_BASE=1 in
# CI/prod to fail the build unless BASE_IMAGE is digest-pinned (contains `@sha256:`). A digest needs
# the `@` separator, which is why BASE_IMAGE is a full reference.
ARG BASE_IMAGE
ARG REQUIRE_PINNED_BASE=
RUN set -e; \
    if [ -n "$REQUIRE_PINNED_BASE" ] && ! printf '%s' "$BASE_IMAGE" | grep -q '@sha256:'; then \
        echo "ERROR: BASE_IMAGE must be digest-pinned (e.g. .../maarg-base-os@sha256:<digest>) for CI/prod builds (got '$BASE_IMAGE')." >&2; \
        exit 1; \
    fi

ARG GIT_USERNAME=
ARG GIT_PASSWORD=
# moqui-framework: pinned to the drpn-ai FORK, tag v4.0.0-drpn.1 (annotated; dereferences to
# c618faf1). That tag is d12a86e — upstream v4.0.0 + PR #705 (embed-bitronix), the merge this stack
# requires, since Bitronix is the default JTA TM and moqui-atomikos is retired — PLUS one commit:
# the login self-deadlock fix in MoquiShiroRealm. Without that fix, the reset UPDATE holds an X lock
# on USER_ACCOUNT while the FK-child UserLoginKey insert runs in a suspended transaction, so every
# returning user's login stalls until innodb_lock_wait_timeout. Upstream has neither the fix nor any
# tag containing Bitronix (the v4.0.0 tag predates that merge by 6 commits).
#
# Why a TAG and not the branch or the raw SHA: the RUN below does
# `git fetch --depth 1 origin "$MOQUI_FRAMEWORK_REF"`, which needs the ref to be reachable on the
# remote. A raw SHA is not fetchable by default, and the fork branch it currently sits on
# (fix/login-userloginkey-deadlock) will be rebased or deleted once the fix goes upstream — either
# would break this image build. The tag is immutable and survives both.
#
# RETIREMENT: when the fix is merged upstream, repoint this ARG, docker/prod/Dockerfile, and the
# darpan component's .github/workflows/ci.yml framework clone at an upstream ref that contains it,
# and drop the fork. All three must move together, or CI stops testing what production actually
# runs. (This file builds the dev/UAT/CI image; docker/prod/Dockerfile builds production. Both are
# pinned to the same framework tag on purpose.)
#
# moqui-runtime v3.9.9 == dev baseline (upstream v4.0.0 adds Groovy 5 + Gradle bumps; adopt in dev
# first, then bump here). moqui-sftp v1.0.3 is the latest upstream tag. All three are stable
# immutable refs; no build-arg override is required.
ARG MOQUI_FRAMEWORK_REF=v4.0.0-drpn.1
ARG MOQUI_RUNTIME_REF=v3.9.9
# moqui-atomikos retired: Moqui 4 embeds Bitronix as the default JTA TM; no separate Atomikos component needed.
ARG MOQUI_SFTP_REF=v1.0.3
ARG DARPAN_REF=main
ARG DARPAN_HOTWAX_REF=main
ARG SHOPIFY_DARPAN_REF=main
ARG NETSUITE_DARPAN_REF=main
ARG DATABASE_DARPAN_REF=main
ARG MOQUI_GQL_REF=main

WORKDIR /

# Audit W5 #37 — credentials live ONLY for the duration of this RUN, mounted from BuildKit's
# secret store at /run/secrets/netrc. The earlier `echo $GIT_PASSWORD >> /root/.netrc` pattern
# preserved the credential in image layer history (recoverable via `docker history --no-trunc`).
# Backward-compat fallback writes the netrc from the legacy ARGs IF the BuildKit secret is absent,
# all collapsed into a single RUN so the credential file is removed in the same layer.
RUN --mount=type=secret,id=netrc,target=/root/.netrc.secret,required=false \
    set -e; \
    if [ -s /root/.netrc.secret ]; then \
        cp /root/.netrc.secret /root/.netrc; \
    else \
        printf 'machine github.com\nlogin %s\npassword %s\n' "$GIT_USERNAME" "$GIT_PASSWORD" > /root/.netrc; \
    fi; \
    chmod 600 /root/.netrc; \
    git init /moqui-framework && git -C /moqui-framework remote add origin https://github.com/drpn-ai/moqui-framework.git && git -C /moqui-framework fetch --depth 1 origin "$MOQUI_FRAMEWORK_REF" && git -C /moqui-framework checkout --detach FETCH_HEAD; \
    git clone --depth 1 -b "$MOQUI_RUNTIME_REF"   https://github.com/moqui/moqui-runtime.git    /moqui-framework/runtime; \
    git clone --depth 1 -b "$MOQUI_SFTP_REF"      https://github.com/moqui/moqui-sftp.git       /moqui-framework/runtime/component/moqui-sftp; \
    git clone --depth 1 -b "$DARPAN_REF"          https://github.com/drpn-ai/darpan.git          /moqui-framework/runtime/component/darpan; \
    git clone --depth 1 -b "$DARPAN_HOTWAX_REF"   https://github.com/drpn-ai/darpan-hotwax.git  /moqui-framework/runtime/component/darpan-hotwax; \
    git clone --depth 1 -b "$SHOPIFY_DARPAN_REF"  https://github.com/drpn-ai/shopify-darpan.git /moqui-framework/runtime/component/shopify-darpan; \
    git clone --depth 1 -b "$NETSUITE_DARPAN_REF" https://github.com/drpn-ai/netsuite-darpan.git /moqui-framework/runtime/component/netsuite-darpan; \
    git clone --depth 1 -b "$DATABASE_DARPAN_REF" https://github.com/drpn-ai/database-darpan.git /moqui-framework/runtime/component/database-darpan; \
    git clone --depth 1 -b "$MOQUI_GQL_REF"       https://github.com/drpn-ai/moqui-gql.git      /moqui-framework/runtime/component/moqui-gql; \
    rm -f /root/.netrc

WORKDIR /moqui-framework

# Fix 2026-06-27: GRADLE_USER_HOME must land inside /moqui-framework/ (already chowned to moqui)
# so the non-root moqui user can write the Gradle distribution during addRuntime and upgrade-data loads.
ENV GRADLE_USER_HOME=/moqui-framework/.gradle

# Make Temurin 21 the default JDK for BOTH the build (Gradle 9 needs JVM 17+; the addRuntime step
# below fails on the base image's default JDK 11) and the runtime (`exec java` MoquiStart + the
# entrypoint's gradlew upgrade-data load — Moqui 4 needs JDK 21). Overrides the base image's JDK 11.
COPY --from=jdk21 /opt/java/openjdk /opt/java/openjdk
ENV JAVA_HOME=/opt/java/openjdk
ENV PATH="/opt/java/openjdk/bin:${PATH}"

# Fail the build immediately if the active java is not JDK 21 (e.g. base-image PATH drift
# re-exposing its bundled JDK 11). Everything downstream (Gradle 9, Moqui 4, Spark 3.5) requires 21.
RUN java -version 2>&1 | grep -q 'version "21' \
    || { echo "ERROR: active java is not JDK 21:" >&2; java -version >&2; exit 1; }

# Copy production configuration from the BUILD CONTEXT (repo root of darpan-docker-config —
# build with `docker build -f docker/Dockerfile .`). This repo is the sole home of the Docker
# config; the darpan component's embedded docker/ directory was removed 2026-07-04 (1af89e7),
# so nothing may be copied out of the cloned component anymore.
COPY docker/MoquiProductionConf.xml runtime/conf/
# Guard the SameSite swap: if the upstream framework ever drops the LAX marker, this would silently
# no-op and downgrade cookie policy. Fail the docker build instead.
RUN grep -q '__SAME_SITE_LAX__' framework/src/main/webapp/WEB-INF/web.xml \
    && sed -i 's/__SAME_SITE_LAX__/__SAME_SITE_NONE__/g' framework/src/main/webapp/WEB-INF/web.xml
# Guard the framework build.gradle patch (adds the Spark --add-exports for JDK 17/21 and flips the
# run/load tasks to append-form jvmArgs). The patch is coupled to the framework build.gradle structure
# at MOQUI_FRAMEWORK_REF; if that ref is bumped and upstream build.gradle drifts, a bare `git apply`
# fails with a cryptic "patch does not apply" at a line number. Dry-run first, fail loudly with a
# regeneration hint, then apply for real.
COPY docker/buildGradle.patch /tmp/buildGradle.patch
RUN git apply --check /tmp/buildGradle.patch 2>/dev/null \
    || { echo "ERROR: buildGradle.patch no longer applies to moqui-framework @ ${MOQUI_FRAMEWORK_REF}." >&2; \
         echo "       Upstream build.gradle has drifted from what the patch targets. Regenerate it:" >&2; \
         echo "       check out moqui-framework at that ref, re-apply the Spark --add-exports +" >&2; \
         echo "       append-form jvmArgs edits, then 'git diff build.gradle' >" >&2; \
         echo "       docker/buildGradle.patch in darpan-docker-config, and rebuild." >&2; \
         exit 1; }; \
    git apply /tmp/buildGradle.patch && rm -f /tmp/buildGradle.patch

#Create war file. Build the moqui-gql engine jar FIRST: it contributes a GqlToolFactory loaded at
# ECF init and vendors graphql-java into its lib/. Nothing depends on it in the build graph (it
# compileOnly-depends on darpan, not vice-versa), so addRuntime alone would not build it and the
# server would fail to load the component at startup.
RUN ./gradlew :runtime:component:moqui-gql:jar addRuntime

#Extract war file.
WORKDIR /moqui-deploy
COPY docker/entrypoint.sh /moqui-deploy/entrypoint.sh

RUN chmod +x entrypoint.sh
RUN jar -xvf /moqui-framework/moqui-plus-runtime.war

# DB_LOAD is the ops-runbook command for a first-time full DB load (entrypoint.sh does NOT run it).
# darpan-seed-initial/darpan-seed must be INSIDE -Ptypes — loadProduction only forwards -Ptypes; a
# -Praw flag is read by no gradle task (silent no-op). Loader flags go as MoquiStart args instead,
# e.g.: java -jar moqui-plus-runtime.war load conf=$CONF_FILE types=darpan-seed dummy-fks
ENV DB_LOAD="./gradlew loadProduction -Ptypes=seed,seed-initial,install,ext-seed,ext,darpan-seed-initial,darpan-seed"
# Audit 2026-06-27 MACH P1 #1: replaced hardcoded -Xms512m/-Xmx4096m with cgroup-aware JDK 21
# container support. JDK 21 respects cgroup v1/v2 memory limits by default (UseContainerSupport=true).
# -XX:MaxRAMPercentage=75.0 caps the heap at 75 % of the container's cgroup limit (leaves headroom for
# Metaspace, thread stacks, NIO direct buffers, and the OS). -XX:InitialRAMPercentage=25.0 avoids
# over-eager reservation at start. Override the entire JAVA_OPTS env var at runtime to change these.
ENV JAVA_OPTS="-XX:InitialRAMPercentage=25.0 -XX:MaxRAMPercentage=75.0 -XX:MaxHeapSize=6g"
ENV CONF_FILE="/moqui-framework/runtime/conf/MoquiProductionConf.xml"
ENV SLEEP="sleep 2"
ENV JWT_KEY=
ENV MOQUI_HOST=
ENV Moqui_DB_HOST=
ENV Moqui_DB_USER=
ENV Moqui_DB_PASSWORD=
ENV Moqui_DB_NAME=
# TEMPORARY 2026-07-02: '*' appended so any origin passes the Moqui allowlist while the UAT ingress
# CORS rewrite is investigated. REVERT once the ingress stops stamping Access-Control-Allow-Origin: *.
# Note the wildcard alone does NOT fix credentialed (cookie-auth) browser requests — browsers reject
# ACAO '*' with credentials regardless of what the backend allows; the ingress header is the blocker.
# This Dockerfile builds the UAT-track image (DARPAN_REF=main); prod/Dockerfile stays strict.
ENV Moqui_WEBAPP_ALLOW_ORIGINS="*,darpan-app-uat.hotwax.io,darpan-app.hotwax.io,darpan-uat.hotwax.io,darpan.hotwax.io,hotwax-darpan-dev.web.app,hotwax-darpan-dev.firebaseapp.com,hc-darpan-uat.web.app,hc-darpan-uat.firebaseapp.com,hc-darpan.web.app,hc-darpan.firebaseapp.com,app-uat.drpn.ai,app.drpn.ai"
ENV WEBAPP_ALLOW_ORIGINS=
ENV ELASTICSEARCH_HOST=
ENV TIME_ZONE=

# Audit 2026-06-26 MACH P0 #1: guarantee the healthcheck probe tool exists regardless of base-image
# contents (idempotent — no-op when curl is already present).
RUN command -v curl >/dev/null 2>&1 || (apt-get update && apt-get install -y --no-install-recommends curl && rm -rf /var/lib/apt/lists/*)

# TEMP 2026-07-02 — non-root USER moqui (MACH P1 #1, 2026-06-27) removed: the UAT datamanager
# volume carries root-owned run directories from pre-hardening images and the deployment does not
# yet set securityContext.fsGroup, so uid-1000 writes failed (AccessDeniedException on new
# reconciliation-run dirs). Container runs as root until then. REINSTATE the moqui user once the
# pod spec sets fsGroup: 1000 (+ fsGroupChangePolicy: OnRootMismatch) or the volume ownership is
# fixed via a one-time root init container; a pod securityContext with runAsNonRoot: true must also
# be dropped while this is in effect.

EXPOSE 8080

# /status is bound to 127.0.0.1 (IP-allowlisted) and excluded from server-stats, so in-container health
# polling is cheap and side-effect-free. start-period covers JVM boot + the per-boot upgrade-data load.
HEALTHCHECK --interval=30s --timeout=10s --start-period=300s --retries=3 \
    CMD curl -fsS http://127.0.0.1:8080/status || exit 1

# Audit 2026-06-26 MACH P0 #1: exec-form ENTRYPOINT so ./entrypoint.sh runs as PID 1 (no `/bin/sh -c`
# wrapper); the script's trailing `exec java` then becomes PID 1 and receives SIGTERM directly for an
# orderly Moqui shutdown + Bitronix XA flush. Dropped the dead `&& bash` (unreachable — `tail -F` never
# returned; PID-1 java now holds the container open and `docker stop` works as intended).
ENTRYPOINT ["./entrypoint.sh"]
