# syntax=docker/dockerfile:1

# Base image policy (PAP ADR 0017, Julia profile; ADR 0026 in this repository):
# the official Julia image on the current Debian stable release, with the OS
# release named in the tag (A4). The Julia patch version is pinned to match CI
# and every Manifest.toml (ADR 0026 revision 1; step 3 of
# scripts/verify_batch_container.sh fails on a mismatch with Manifest.toml); the
# frozen tag is made current by the upgrade step in the
# runtime stage (A5). Build and runtime stages must use the same tag so the
# package images compiled below match the runtime Julia binary.
FROM julia:1.13.1-trixie AS build

ENV JULIA_DEPOT_PATH=/opt/julia-depot \
    JULIA_PKG_PRECOMPILE_AUTO=0 \
    JULIA_NUM_PRECOMPILE_TASKS=2

WORKDIR /opt/dme

# Dependency resolution is isolated from source changes so Docker can reuse the
# package-download layer. Manifest.toml is required: do not replace this with
# `Pkg.update()` or an unpinned install in the image build.
COPY Project.toml Manifest.toml ./
RUN julia --compiled-modules=no --project=. \
    -e 'using Pkg; Pkg.instantiate(; allow_autoprecomp=false)'

COPY src ./src

# Load and execute the representative task in the same project and depot paths
# used at runtime. `using DME` writes Julia's package cache, so the runtime
# never compiles into the (read-only) depot and does not load Pkg at startup.
RUN julia --project=. -e 'using DME; exit(DME.dme_main(["simulate", "solow", "--periods", "4", "--out", "/tmp/dme-build-artifacts"]))'

FROM julia:1.13.1-trixie AS runtime

# A5: install every update published in trixie's own repositories on the
# freshly pulled base. Nothing is installed from another release.
RUN apt-get update \
    && apt-get upgrade --yes --no-install-recommends \
    && rm -rf /var/lib/apt/lists/*

ENV JULIA_PROJECT=/opt/dme \
    JULIA_DEPOT_PATH=/opt/julia-depot \
    JULIA_PKG_PRECOMPILE_AUTO=0 \
    DME_ARTIFACT_OUTDIR=/var/lib/dme/artifacts

# The runtime user owns only the artifact directory. The project source and the
# Julia depot stay root-owned, so the image works with readonlyRootFilesystem
# and the process cannot modify its own code even when the root is writable.
RUN groupadd --gid 10001 dme \
    && useradd --uid 10001 --gid dme --create-home --shell /usr/sbin/nologin dme \
    && install --directory --owner dme --group dme --mode 0755 /var/lib/dme/artifacts

WORKDIR /opt/dme

COPY --from=build /opt/dme/Project.toml /opt/dme/Manifest.toml ./
COPY --from=build /opt/dme/src ./src
COPY --from=build /opt/julia-depot /opt/julia-depot
COPY --chmod=755 bin/dme /usr/local/bin/dme

# The artifact directory is the only path DME writes. A task definition mounts
# a volume here (or passes --out / DME_ARTIFACT_OUTDIR to another volume).
VOLUME ["/var/lib/dme/artifacts"]

USER 10001:10001

# Run Julia as PID 1, so ECS delivers SIGTERM directly and its resulting exit
# status remains the task exit status without an intervening shell.
STOPSIGNAL SIGTERM
ENTRYPOINT ["dme"]
CMD ["simulate", "solow"]

# Provenance comes last so that a new commit does not invalidate the layers
# above. The run manifest reads DME_SOURCE_COMMIT and DME_IMAGE_VERSION, and the
# OCI labels carry the same values for ECR, PAP admission (A1) and A8 evidence.
ARG DME_SOURCE_COMMIT=unknown
ARG DME_IMAGE_VERSION=0.1.0-dev
LABEL org.opencontainers.image.source="https://github.com/Yuki-Watanabe7/DME" \
    org.opencontainers.image.revision="${DME_SOURCE_COMMIT}" \
    org.opencontainers.image.version="${DME_IMAGE_VERSION}" \
    org.opencontainers.image.title="dme" \
    org.opencontainers.image.description="DME batch CLI (dme simulate / dme quality-export)"
ENV DME_SOURCE_COMMIT=${DME_SOURCE_COMMIT} \
    DME_IMAGE_VERSION=${DME_IMAGE_VERSION}
