# syntax=docker/dockerfile:1

# Keep this value aligned with the Julia version used by CI and recorded in
# Manifest.toml. The versioned official image gives ECS tasks a reproducible
# Julia runtime rather than inheriting a host installation.
FROM julia:1.12.6-bookworm AS build

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
# used at runtime. `using DME` writes Julia's package cache, and this warm-up
# compiles the stable CLI and Solow execution path without loading Pkg at task
# startup.
RUN julia --project=. -e 'using DME; exit(DME.dme_main(["simulate", "solow", "--periods", "4", "--out", "/tmp/dme-build-artifacts"]))'

FROM julia:1.12.6-bookworm AS runtime

ENV JULIA_PROJECT=/opt/dme \
    JULIA_DEPOT_PATH=/opt/julia-depot \
    JULIA_PKG_PRECOMPILE_AUTO=0 \
    DME_ARTIFACT_OUTDIR=/var/lib/dme/artifacts

RUN groupadd --gid 10001 dme \
    && useradd --uid 10001 --gid dme --create-home --shell /usr/sbin/nologin dme \
    && mkdir --parents /opt/dme /opt/julia-depot /var/lib/dme/artifacts \
    && chown --recursive dme:dme /opt/dme /opt/julia-depot /var/lib/dme/artifacts

WORKDIR /opt/dme

COPY --from=build --chown=dme:dme /opt/dme/Project.toml /opt/dme/Manifest.toml ./
COPY --from=build --chown=dme:dme /opt/dme/src ./src
COPY --from=build --chown=dme:dme /opt/julia-depot /opt/julia-depot
COPY --chmod=755 bin/dme /usr/local/bin/dme

USER 10001:10001

# Run Julia as PID 1, so ECS delivers SIGTERM directly and its resulting exit
# status remains the task exit status without an intervening shell.
STOPSIGNAL SIGTERM
ENTRYPOINT ["dme"]
CMD ["simulate", "solow"]
