# syntax=docker/dockerfile:1

FROM python:3.15-slim-trixie AS repo-builder

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        apt-utils \
        aria2 \
        busybox \
        ca-certificates \
        curl \
        gnupg \
        gpgv \
        wget wget2 && \
    rm -rf /var/lib/apt/lists/*

RUN --mount=type=secret,id=apt_signing_key,required=true \
    --mount=type=secret,id=openresty_mirror_pub,required=true \
    --mount=type=secret,id=openresty_upstream_pub,required=true \
    --mount=type=bind,source=build.sh,target=/run/build.sh \
    set -eux; \
    install -d -m 0755 -o 0 -g 0 /etc/apt/keyrings; \
    install -m 0644 -o 0 -g 0 /run/secrets/openresty_upstream_pub /etc/apt/keyrings/openresty-upstream.asc; \
    install -m 0644 -o 0 -g 0 /run/secrets/openresty_mirror_pub /etc/apt/keyrings/openresty-mirror.asc; \
    bash /run/build.sh

FROM python:3.15-slim-trixie AS artifact-builder

RUN --mount=type=bind,from=repo-builder,target=/run/repo,readonly \
    tar --numeric-owner -C /run/repo -cf /repo-artifact.tar etc/apt srv

FROM scratch AS artifact
COPY --from=artifact-builder /repo-artifact.tar /repo-artifact.tar

FROM python:3.15-slim-trixie AS final

COPY --from=repo-builder --chown=0:0 --chmod=0644 /etc/apt/keyrings/openresty-upstream.asc /etc/apt/keyrings/openresty-upstream.asc
COPY --from=repo-builder --chown=0:0 --chmod=0644 /etc/apt/keyrings/openresty-mirror.asc /etc/apt/keyrings/openresty-mirror.asc
COPY --from=repo-builder --chown=0:0 --chmod=0644 /srv/repo /srv/repo
RUN find /srv/repo -type d -exec chmod 0755 {} +

VOLUME ["/srv/repo"]

USER 65534:65534
EXPOSE 8080

ENTRYPOINT ["python3", "-m", "http.server", "--directory", "/srv/repo"]
CMD ["--bind", "0.0.0.0", "8080"]
