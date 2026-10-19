# darpan-docker-config

Docker build and runtime configuration for the Darpan backend, extracted from
`drpn-ai/darpan` (`docker/` directory) on 2026-07-03.

## Layout

Everything lives under `docker/` so standard CI job templates (`docker build -f docker/Dockerfile .`)
work against this repo without per-job path overrides.

| Path | Purpose |
|---|---|
| `docker/Dockerfile` | Dev/UAT/CI image build (components default to `main`) |
| `docker/prod/Dockerfile` | Production image build — product components pinned to release tags |
| `docker/entrypoint.sh`, `docker/prod/entrypoint.sh` | Container entrypoints; export required JVM flags (Spark `--add-opens`, dynamic agent loading) and enforce the fail-fast secret gate |
| `docker/MoquiProductionConf.xml` | Moqui production runtime conf baked into the image |
| `docker/log4j2-json.xml` | JSON log output config for containerized runs |
| `docker/buildGradle.patch` | Build patch applied during image build |
| `docker/compose.local.yml` | Local harness (Postgres + darpan image) — NOT for production |
| `docker/.env.local.example` | Template for the git-ignored `.env.local` used by the local compose harness |

## Build notes

- Build from the REPO ROOT so the Dockerfiles' `COPY docker/...` context paths resolve:
  - UAT/CI: `docker build -f docker/Dockerfile .`
  - prod: `docker build -f docker/prod/Dockerfile .`
- Config files (`MoquiProductionConf.xml`, `buildGradle.patch`, entrypoints, `log4j2-json.xml`) are
  COPY'd from this repo's build context. They are NOT taken from the cloned darpan component — its
  embedded `docker/` directory was removed 2026-07-04 (`drpn-ai/darpan` 1af89e7).
- CI/prod builds MUST digest-pin the base image: `--build-arg BASE_IMAGE=maarg-base-os@sha256:<d>` and `--build-arg REQUIRE_PINNED_BASE=1`.
- GitHub credentials go in via BuildKit secrets (`--secret id=netrc,...`), never build args. The `GIT_USERNAME`/`GIT_PASSWORD` build args still exist as a fallback; do not use them.
- `.env.local` holds real secrets (JWT key, DB credentials) and is git-ignored — copy `.env.local.example` and fill it in locally.

## Component pins

The two Dockerfiles clone the same component set. UAT tracks branch heads; prod pins product
components to release tags. Values below are the `ARG` defaults in each file.

| Component | Repo | `docker/Dockerfile` (UAT/CI) | `docker/prod/Dockerfile` |
|---|---|---|---|
| moqui-framework | `drpn-ai/moqui-framework` (fork) | `master` | `master` (moves; pass `MOQUI_FRAMEWORK_REF=<sha>` for a reproducible build) |
| moqui-runtime | `moqui/moqui-runtime` | `v3.9.9` | `v3.9.9` |
| moqui-sftp | `moqui/moqui-sftp` | `v1.0.3` | `v1.0.3` |
| darpan | `drpn-ai/darpan` | `main` | `v1.5.1` |
| darpan-hotwax | `drpn-ai/darpan-hotwax` | `main` | `v0.8.0` |
| shopify-darpan | `drpn-ai/shopify-darpan` | `main` | `v0.6.1` |
| netsuite-darpan | `drpn-ai/netsuite-darpan` | `main` | `v0.2.0` |
| database-darpan | `drpn-ai/database-darpan` | `main` | `v0.2.0` |
| moqui-gql | `drpn-ai/moqui-gql` | `main` | `main` (no release tag yet; pin one before exposing the public tier) |

Pins move together. A darpan tag's seed data can name services or record fields that exist only in
a matching component tag, so when `DARPAN_REF` moves, check `DARPAN_HOTWAX_REF`,
`SHOPIFY_DARPAN_REF`, and the others in the same change. The comments above the `ARG` block in
`docker/prod/Dockerfile` record why each pairing exists.

## Edit both Dockerfiles

`docker/Dockerfile` and `docker/prod/Dockerfile` are separate files with no shared include. A change
to the component list, the framework ref, config `COPY` lines, JVM flags, the SameSite guard, or the
build patch must be made in both, or the UAT image stops testing what prod runs. The same applies to
`docker/entrypoint.sh` and `docker/prod/entrypoint.sh`. Compare them with
`diff docker/Dockerfile docker/prod/Dockerfile` before committing.

## UAT CORS and cookie posture (temporary)

- `docker/Dockerfile` prepends `*` to `Moqui_WEBAPP_ALLOW_ORIGINS`. `docker/prod/Dockerfile` ships an
  exact origin list. Both entrypoints write `Moqui_WEBAPP_ALLOW_ORIGINS` (or
  `WEBAPP_ALLOW_ORIGINS`) into `webapp_allow_origins` in `MoquiProductionConf.xml` at boot.
- The `*` dates from 2026-07-02: the UAT ingress rewrites `Access-Control-Allow-Origin` to `*`, so
  darpan-ui on UAT uses header auth (`VITE_DARPAN_COOKIE_AUTH=false`) instead of the HttpOnly cookie.
- Both Dockerfiles replace the framework `web.xml` `__SAME_SITE_LAX__` marker with
  `__SAME_SITE_NONE__`, so framework cookies are `SameSite=None` in both images. The darpan login
  cookie sets its own SameSite per request.
- Reverting is tracked as DAR-OPS-001. Order matters: remove `*` here (and redeploy) before or with
  the ingress fix, and only then switch UAT darpan-ui to cookie auth. The full sequence is in
  darpan-ui `docs/auth-and-cors-by-environment.md`.
- Neither Dockerfile sets a `USER`, so both images run as root (temporary since 2026-07-02;
  DAR-OPS-002).

## Provenance

Files were copied verbatim from the `docker/` directory of the darpan Moqui
component. In-file comments may still reference `docker/`-relative paths from
the original embedded location.
