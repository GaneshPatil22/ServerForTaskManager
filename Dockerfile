# Brain server image. Multi-arch (arm64 for Oracle Ampere, amd64 elsewhere).
#   docker build -t brain-server .
# Brain is fetched from its pinned git tag (BRAIN_FROM_GIT=1), so the image
# never depends on a ../Brain checkout.

# ---- build ----
FROM swift:6.4.3-noble AS build
WORKDIR /build
ENV BRAIN_FROM_GIT=1
COPY Package.swift Package.resolved ./
RUN swift package resolve
COPY Sources ./Sources
# Tests is copied only because Package.swift declares targets there; nothing
# from it reaches the final image.
COPY Tests ./Tests
RUN swift build -c release --static-swift-stdlib --product brain-server \
    && mkdir /staging \
    && cp "$(swift build -c release --show-bin-path)/brain-server" /staging/ \
    && cp /usr/libexec/swift/linux/swift-backtrace-static /staging/

# ---- run ----
FROM ubuntu:noble
# ca-certificates: TLS to Supabase and Google. tzdata: IANA timezones, without
# which "Asia/Kolkata" (and every user's "today") would silently fail.
# libcurl4: FoundationNetworking, linked by a dependency (found with ldd: the
# image without it could not start).
RUN export DEBIAN_FRONTEND=noninteractive \
    && apt-get -q update \
    && apt-get -q install -y --no-install-recommends ca-certificates tzdata libcurl4 \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --system --create-home --home-dir /app brain
WORKDIR /app
COPY --from=build --chown=brain:brain /staging /app
ENV SWIFT_BACKTRACE=enable=yes,sanitize=yes,threads=all,images=all,interactive=no,swift-backtrace=./swift-backtrace-static
USER brain
EXPOSE 8080
ENTRYPOINT ["./brain-server"]
CMD ["--hostname", "0.0.0.0", "--port", "8080"]
