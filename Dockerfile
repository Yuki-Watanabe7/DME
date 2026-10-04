# syntax=docker/dockerfile:1
# Production base selected through the measured Issue #296 comparison (ADR 0026 revision 3).
# Build and runtime use the same AL2023 + official glibc Julia installation.
# Never copy a Debian-precompiled depot into the older AL2023 glibc runtime.
FROM public.ecr.aws/amazonlinux/amazonlinux:2023-minimal AS julia-base

RUN microdnf upgrade -y \
    && microdnf install -y ca-certificates libatomic libstdc++ shadow-utils findutils \
    && microdnf clean all

# Checksums from the official release, reviewed with this Dockerfile:
# https://julialang-s3.julialang.org/bin/checksums/julia-1.13.1.sha256
# Keep the patch in sync with CI and all Manifests; never accept a build-time
# version override. Download/extraction tools are removed in the same layer.
RUN microdnf install -y tar gzip \
    && case "$(uname -m)" in \
         x86_64) julia_arch=x64; julia_file_arch=x86_64; julia_sha=0f2e18c8dea60a2c8711d089cd9612f7a8df394b89e5208096fe5867647e0908 ;; \
         aarch64) julia_arch=aarch64; julia_file_arch=aarch64; julia_sha=78341862e24734ea1c2fa8795183c52627c23a99aba5aa1d0ec840edecec5ce0 ;; \
         *) exit 1 ;; \
       esac \
    && curl --fail --location --retry 3 --connect-timeout 20 --max-time 600 --silent --show-error \
         "https://julialang-s3.julialang.org/bin/linux/${julia_arch}/1.13/julia-1.13.1-linux-${julia_file_arch}.tar.gz" \
         --output /tmp/julia.tar.gz \
    && echo "${julia_sha}  /tmp/julia.tar.gz" | sha256sum --check --strict \
    && mkdir -p /usr/local/julia \
    && tar -xzf /tmp/julia.tar.gz -C /usr/local/julia --strip-components=1 \
    && rm /tmp/julia.tar.gz \
    && microdnf remove -y tar gzip \
    && microdnf clean all

ENV PATH=/usr/local/julia/bin:$PATH

FROM julia-base AS build
ENV JULIA_DEPOT_PATH=/opt/julia-depot \
    JULIA_PKG_PRECOMPILE_AUTO=0 \
    JULIA_NUM_PRECOMPILE_TASKS=2
WORKDIR /opt/dme
COPY Project.toml Manifest.toml ./
RUN julia --compiled-modules=no --project=. \
    -e 'using Pkg; Pkg.instantiate(; allow_autoprecomp=false)'
COPY src ./src
RUN julia --project=. -e 'using DME; exit(DME.dme_main(["simulate", "solow", "--periods", "4", "--out", "/tmp/dme-build-artifacts"]))'

FROM julia-base AS runtime
# A5: run the upgrade in the runtime stage as well, even on a reused build layer.
RUN microdnf upgrade -y && microdnf clean all
ENV JULIA_PROJECT=/opt/dme \
    JULIA_DEPOT_PATH=/opt/julia-depot \
    JULIA_PKG_PRECOMPILE_AUTO=0 \
    DME_ARTIFACT_OUTDIR=/var/lib/dme/artifacts
RUN groupadd --gid 10001 dme \
    && useradd --uid 10001 --gid dme --create-home --shell /sbin/nologin dme \
    && install --directory --owner dme --group dme --mode 0755 /var/lib/dme/artifacts
WORKDIR /opt/dme
COPY --from=build /opt/dme/Project.toml /opt/dme/Manifest.toml ./
COPY --from=build /opt/dme/src ./src
COPY --from=build /opt/julia-depot /opt/julia-depot
COPY --chmod=755 bin/dme /usr/local/bin/dme
VOLUME ["/var/lib/dme/artifacts"]
USER 10001:10001
STOPSIGNAL SIGTERM
ENTRYPOINT ["dme"]
CMD ["simulate", "solow"]
ARG DME_SOURCE_COMMIT=unknown
ARG DME_IMAGE_VERSION=0.1.0-dev
ARG DME_BASE_REFERENCE=public.ecr.aws/amazonlinux/amazonlinux:2023-minimal
ARG DME_BASE_DIGEST=unknown
LABEL org.opencontainers.image.source="https://github.com/Yuki-Watanabe7/DME" \
    org.opencontainers.image.revision="${DME_SOURCE_COMMIT}" \
    org.opencontainers.image.version="${DME_IMAGE_VERSION}" \
    org.opencontainers.image.title="dme" \
    org.opencontainers.image.description="DME batch CLI (dme simulate / dme quality-export)" \
    org.opencontainers.image.base.name="${DME_BASE_REFERENCE}" \
    org.opencontainers.image.base.digest="${DME_BASE_DIGEST}"
ENV DME_SOURCE_COMMIT=${DME_SOURCE_COMMIT} \
    DME_IMAGE_VERSION=${DME_IMAGE_VERSION}
