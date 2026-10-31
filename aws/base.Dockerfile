# DAR-OPS-006. Darpan-owned base image: stock Ubuntu 22.04 (multi-arch, so it runs on Fargate ARM64)
# plus the three tools docker/Dockerfile expects from its base. Replaces HotWax's amd64-only
# public.ecr.aws/j6s7y7u4/hotwax/ubuntu:22.04, whose extra JDKs and Gradle the build never uses
# (docker/Dockerfile copies Temurin 21 and runs ./gradlew).
#
#   docker build -f aws/base.Dockerfile -t darpan-base:22.04 .
#   docker build -f docker/Dockerfile --build-arg BASE_IMAGE=darpan-base:22.04 -t darpan:uat .
FROM ubuntu:22.04@sha256:076e7bf82319619f28dd0aa9c02ab34b055ad37100395b4f49a2ffba04fb5e11

RUN apt-get update \
    && apt-get upgrade -y --no-install-recommends \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends ca-certificates curl git tzdata \
    && rm -rf /var/lib/apt/lists/*
