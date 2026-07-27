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
- GitHub credentials go in via BuildKit secrets (`--secret id=netrc,...`), never build args.
- `.env.local` holds real secrets (JWT key, DB credentials) and is git-ignored — copy `.env.local.example` and fill it in locally.

## Provenance

Files were copied verbatim from the `docker/` directory of the darpan Moqui
component. In-file comments may still reference `docker/`-relative paths from
the original embedded location.
