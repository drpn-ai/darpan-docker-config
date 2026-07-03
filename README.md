# darpan-docker-config

Docker build and runtime configuration for the Darpan backend, extracted from
`drpn-ai/darpan` (`docker/` directory) on 2026-07-03.

## Layout

| Path | Purpose |
|---|---|
| `Dockerfile` | Dev/CI image build (components default to `main`) |
| `prod/Dockerfile` | Production image build — product components pinned to release tags |
| `entrypoint.sh`, `prod/entrypoint.sh` | Container entrypoints; export required JVM flags (Spark `--add-opens`, dynamic agent loading) and enforce the fail-fast secret gate |
| `MoquiProductionConf.xml` | Moqui production runtime conf baked into the image |
| `log4j2-json.xml` | JSON log output config for containerized runs |
| `buildGradle.patch` | Build patch applied during image build |
| `compose.local.yml` | Local harness (Postgres + darpan image) — NOT for production |
| `.env.local.example` | Template for the git-ignored `.env.local` used by the local compose harness |

## Build notes

- CI/prod builds MUST digest-pin the base image: `--build-arg BASE_IMAGE=maarg-base-os@sha256:<d>` and `--build-arg REQUIRE_PINNED_BASE=1`.
- GitHub credentials go in via BuildKit secrets (`--secret id=netrc,...`), never build args.
- `.env.local` holds real secrets (JWT key, DB credentials) and is git-ignored — copy `.env.local.example` and fill it in locally.

## Provenance

Files were copied verbatim from the `docker/` directory of the darpan Moqui
component. In-file comments may still reference `docker/`-relative paths from
the original embedded location.
