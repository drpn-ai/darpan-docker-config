# darpan-docker-config

Docker build and runtime configuration for the Darpan backend, extracted from
`drpn-ai/darpan` (`docker/` directory) on 2026-07-03.

## Layout (`chelan` branch)

This branch mirrors the structure and conventions of `chelan/chelan-docker-config`
on `git.hotwaxsystems.com` (`secure-secrets` branch): docker-first single-stage
builds, `.netrc` credentials removed from the image after cloning, a root + `prod/`
+ `uat/` layout whose Dockerfiles differ only in pinned refs, and the
`DB_HOST`/`DB_PORT`/`DB_USER`/`DB_PASSWORD`/`DB_NAME`/`HC_HOST` runtime env
contract. Chelan runs Postgres; the baked-in conf uses `PGXADataSource`.

| Path | Purpose |
|---|---|
| `Dockerfile` | Chelan work-track image build (components default to `main`) |
| `uat/Dockerfile` | UAT image build (components default to `main`) |
| `prod/Dockerfile` | Production image build — product components pinned to release tags |
| `entrypoint.sh`, `uat/entrypoint.sh`, `prod/entrypoint.sh` | Identical entrypoint copies (one per track, matching the GitLab layout): fail-fast secret gate, conf templating from `DB_*`/`HC_HOST`, Spark `--add-opens` JVM flags, optional upgrade-data load |
| `MoquiProductionConf.xml` | Moqui production runtime conf (Postgres) baked into the image |
| `buildGradle.patch` | Build patch applied during image build |
| `compose.local.yml` | Local harness (Postgres + darpan image) — NOT for production |
| `.env.local.example` | Template for the git-ignored `.env.local` used by the local compose harness |

## Build notes

- Build all three tracks from the repo root: `docker build [-f uat/Dockerfile | -f prod/Dockerfile] --build-arg GIT_USERNAME=<user> --build-arg GIT_PASSWORD=<token> -t darpan:chelan[-uat|-prod] .`
- GIT_USERNAME/GIT_PASSWORD are plain build args (visible in `docker history`) — use a short-lived, read-only token and treat the image as private.
- `.env.local` holds real secrets (JWT key, DB credentials) and is git-ignored — copy `.env.local.example` and fill it in locally.

## Provenance

Files were copied verbatim from the `docker/` directory of the darpan Moqui
component. In-file comments may still reference `docker/`-relative paths from
the original embedded location.
