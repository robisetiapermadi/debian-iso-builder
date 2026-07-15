FROM debian:bookworm-slim

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        xorriso \
        cpio \
        gzip \
        wget \
        ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /work
COPY build.sh /build.sh
RUN chmod +x /build.sh

ENTRYPOINT ["/build.sh"]
