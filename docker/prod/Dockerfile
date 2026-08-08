# syntax=docker/dockerfile:1.6
#
# Audit Wave 5 hardening (mirrors ../Dockerfile):
#  - W5 #36 / 2026-06-11 #24: BASE_IMAGE default still names the latest tag for compatibility; CI/prod
#    MUST override with a digest-pinned reference (`maarg-base-os@sha256:<d>`) for reproducible builds.
#    A digest REQUIRES the `@` separator (a `:sha256:...` tag form is an invalid Docker reference), so
#    BASE_IMAGE is a full reference. Set `--build-arg REQUIRE_PINNED_BASE=1` to FAIL the build unless
#    BASE_IMAGE is digest-pinned.
#  - W5 #37: GitHub credentials via BuildKit `--mount=type=secret` so they never land in image
#    layer history. ARG GIT_USERNAME/GIT_PASSWORD remain as a backward-compat fallback during the
#    CI rollout window.
#  - W5 #38: Product refs pinned to tags (darpan v1.0.3 / darpan-hotwax v0.3.0 / shopify-darpan
#    v0.3.0 / netsuite-darpan v0.2.0).
#    moqui-framework / moqui-runtime / moqui-sftp are pinned in-file to stable immutable refs
#    matching the dev baseline (see the ARG block); build args remain available but no override
#    is required for a reproducible build.
ARG BASE_IMAGE=600735190428.dkr.ecr.us-east-1.amazonaws.com/maarg-base-os:OS-22.04-latest

# JDK 21 provider stage. maarg-base-os ships JDK 11 as the default `java`, but Moqui 4, the upstream
# framework's Gradle 9 (refuses to RUN on < JVM 17), and Spark 3.5 all require JDK 21. Copy a
# self-contained Temurin 21 (Ubuntu/glibc — ABI-compatible with the 22.04 base) instead of depending
# on the base image's apt sources. eclipse-temurin:21-jdk is the same JDK image docker/simple uses.
FROM eclipse-temurin:21-jdk AS jdk21

FROM ${BASE_IMAGE}

ARG BASE_IMAGE
ARG REQUIRE_PINNED_BASE=
RUN set -e; \
    if [ -n "$REQUIRE_PINNED_BASE" ] && ! printf '%s' "$BASE_IMAGE" | grep -q '@sha256:'; then \
        echo "ERROR: BASE_IMAGE must be digest-pinned (e.g. .../maarg-base-os@sha256:<digest>) for CI/prod builds (got '$BASE_IMAGE')." >&2; \
        exit 1; \
    fi

ARG GIT_USERNAME=
ARG GIT_PASSWORD=
# moqui-framework: pinned to the drpn-ai FORK, branch master. That branch is upstream v4.0.0 +
# PR #705 (embed-bitronix), the merge this stack requires, since Bitronix is the default JTA TM and
# moqui-atomikos is retired — PLUS the login self-deadlock fix, merged to the fork's mainline as
# 8cde954b. Without that fix a login deadlocks against itself: getLoginKey issued the FK-child
# UserLoginKey insert under requireNewTransaction, which SUSPENDS a caller already holding an X lock
# on the parent USER_ACCOUNT row, so the insert waits on its own caller until
# innodb_lock_wait_timeout. That is a PRODUCTION defect, which is why this pin moves here and not
# only in the dev/UAT image. Upstream has neither the fix nor any tag containing Bitronix (the
# v4.0.0 tag predates that merge by 6 commits).
#
# Why the fork's master and not a tag: the RUN below does
# `git fetch --depth 1 origin "$MOQUI_FRAMEWORK_REF"`, which needs a ref the remote can resolve, and
# a raw SHA is not fetchable by default. This replaced tag v4.0.0-drpn.1 on 2026-08-18 — that tag
# dereferences to c618faf1 and so PREDATES the getLoginKey fix; anything still pinned to it ships
# the deadlock.
#
# TRADE-OFF, and it is a real one: master MOVES. This build is no longer reproducible — a rebuild
# later resolves to whatever the fork's master is at that moment, including upstream commits merged
# in since, and a force-push to the fork is followed silently. For a byte-identical rebuild, pass an
# immutable SHA: `--build-arg MOQUI_FRAMEWORK_REF=8cde954b` (the merge that carried the fix).
#
# RETIREMENT: when the fix is merged upstream, repoint this ARG, docker/Dockerfile, and the darpan
# component's .github/workflows/ci.yml framework clone at an upstream ref that contains it, and drop
# the fork. All three must move together, or CI stops testing what production actually runs.
#
# moqui-runtime v3.9.9 == dev baseline (upstream v4.0.0 adds Groovy 5 + Gradle bumps; adopt in dev
# first, then bump here). moqui-sftp v1.0.3 is the latest upstream tag. Those two are stable
# immutable refs; MOQUI_FRAMEWORK_REF above is NOT — see the trade-off note.
ARG MOQUI_FRAMEWORK_REF=master
ARG MOQUI_RUNTIME_REF=v3.9.9
# moqui-atomikos retired: Moqui 4 embeds Bitronix as the default JTA TM; no separate Atomikos component needed.
ARG MOQUI_SFTP_REF=v1.0.3
# ─────────────────────────────────────────────────────────────────────────────────────────────────
# TESTING VARIANT — tag v0.0.2 (supersedes 0.0.1). The four drpn-ai product components track `main`
# instead of release tags, so a prod-shaped image can be built from unreleased code. Everything else
# is the production build unchanged: the same hardened base image, prod entrypoint, JSON logging,
# and the prod CORS allowlist (which, unlike docker/Dockerfile, does NOT carry the `*` wildcard).
#
# This variant is NOT a release recipe and deliberately does not live on main:
#   - The image is not reproducible. `main` moves, so the same tag builds different images on
#     different days. The tag pins the recipe, not the result — record the component commit SHAs
#     from the build log if you need to know what you actually deployed.
#   - Nothing here has been through a release cut. Whatever is on main at build time ships, including
#     work that has not been release-tested.
# Build a real release from main, where these refs stay pinned to tags.
#
# The moqui refs above are NOT moved by this variant, and they are not all the same kind of thing:
#   - MOQUI_FRAMEWORK_REF=master is the drpn-ai FORK's master (cloned from drpn-ai/moqui-framework
#     below), so it already IS this project's code — it carries the login/UserLoginKey deadlock fix.
#     Corrected 2026-08-20: an earlier version of this note called it upstream, which it stopped
#     being when f73f181 repointed the pins at the fork.
#   - MOQUI_RUNTIME_REF / MOQUI_SFTP_REF are genuinely upstream moqui/* and stay pinned to tags;
#     MOQUI_RUNTIME_REF in particular is held at v3.9.9 pending the Groovy 5 / Gradle bump.
# ─────────────────────────────────────────────────────────────────────────────────────────────────
#
# darpan history was reset 2026-07-03 (repo detached from the hotwax fork network); pre-reset tags
# no longer exist on the remote. v1.0.0 is the first post-reset tag — never fall back to v1.x/v2.x
# pre-reset refs. Released prod pins this to a tag (v1.4.0 as of this branch point).
ARG DARPAN_REF=main
# darpan-hotwax/shopify-darpan tags below v0.3.0 predate the JDK 21 / Moqui 4 / Gradle 9 migration
# and still declare the removed :runtime:component:moqui-atomikos project — they cannot build on
# this stack. v0.5.0 tags == the component mains cut with darpan v1.2.0 (the seeded connector
# registry rows reference healthCheckServiceName probes, pairLookupServiceName, and the Shopify
# exchange-state/sweep lookups, all introduced in v0.5.0 — move these pins together with
# DARPAN_REF).
# darpan v1.4.0 seeds the OMS_TRANSFER_ORDERS connector registry row, whose extractServiceName and
# remoteSendServiceName both name extract#HotWaxOmsTransferOrders — a service that exists only in
# darpan-hotwax v0.7.0. A v1.4.0/v0.6.0 pairing seeds a connector row pointing at a service the
# image does not contain, so DARPAN_HOTWAX_REF moves with DARPAN_REF.
# shopify-darpan stays at v0.5.0 and netsuite-darpan at v0.2.0 — neither has commits in this range.
# On this testing variant all four move together to main, which keeps that pairing rule satisfied by
# construction: every component is at its own latest, so a seeded connector row cannot reference a
# service that a differently-pinned sibling does not contain. Released prod pins these to tags
# (v0.7.0 / v0.5.0 / v0.2.0 as of this branch point).
ARG DARPAN_HOTWAX_REF=main
ARG SHOPIFY_DARPAN_REF=main
ARG NETSUITE_DARPAN_REF=main
# moqui-gql has no release tag yet (Phase-0/1 component); pin to a tag before exposing the public tier.
ARG MOQUI_GQL_REF=main

WORKDIR /

# Audit W5 #37 — credentials live only for the duration of this RUN, mounted from BuildKit's
# secret store at /run/secrets/netrc. Collapsed into a single RUN so the credential file is
# removed in the same layer that created it.
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
# build with `docker build -f docker/prod/Dockerfile .`). This repo is the sole home of the
# Docker config; the darpan component's embedded docker/ directory was removed 2026-07-04
# (1af89e7), so nothing may be copied out of the cloned component anymore.
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

# Create WAR file. Build the moqui-gql engine jar FIRST: it contributes a GqlToolFactory loaded at
# ECF init and vendors graphql-java into its lib/; nothing depends on it in the build graph, so
# addRuntime alone would not build it and the server would fail to load the component at startup.
RUN ./gradlew :runtime:component:moqui-gql:jar addRuntime

# Extract WAR file.
WORKDIR /moqui-deploy
COPY docker/prod/entrypoint.sh /moqui-deploy/entrypoint.sh
# P1 Observability: copy the JSON log4j2 config so the prod JVM emits structured JSON to STDOUT.
# Activated below via -Dlog4j2.configurationFile. Local dev-stack.sh does NOT set this property
# so developers keep the readable PatternLayout.
COPY docker/log4j2-json.xml /moqui-deploy/log4j2-json.xml

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
# P1 Observability: -Dlog4j2.configurationFile activates the JSON STDOUT layout (log4j2-json.xml).
# This overrides the upstream framework PatternLayout for prod without touching the upstream file.
# The path is absolute inside the extracted WAR directory (/moqui-deploy).
ENV JAVA_OPTS="-XX:InitialRAMPercentage=25.0 -XX:MaxRAMPercentage=75.0 -XX:MaxHeapSize=6g -Dlog4j2.configurationFile=/moqui-deploy/log4j2-json.xml"
ENV CONF_FILE="/moqui-framework/runtime/conf/MoquiProductionConf.xml"
ENV SLEEP="sleep 2"
ENV JWT_KEY=
ENV MOQUI_HOST=
ENV Moqui_DB_HOST=
ENV Moqui_DB_USER=
ENV Moqui_DB_PASSWORD=
ENV Moqui_DB_NAME=
ENV Moqui_WEBAPP_ALLOW_ORIGINS="darpan-app-uat.hotwax.io,darpan-app.hotwax.io,darpan-uat.hotwax.io,darpan.hotwax.io,hotwax-darpan-dev.web.app,hotwax-darpan-dev.firebaseapp.com,hc-darpan-uat.web.app,hc-darpan-uat.firebaseapp.com,hc-darpan.web.app,hc-darpan.firebaseapp.com,app-uat.drpn.ai,app.drpn.ai"
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
