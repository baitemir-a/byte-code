# Build environment for the Linux release: Zig plus the X11 / OpenGL
# development libraries raylib links against. Used by scripts/package.sh:
#   docker build --platform linux/amd64 -t byte-code-linux-build scripts/linux
FROM ubuntu:22.04

RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        ca-certificates curl xz-utils \
        libx11-dev libxrandr-dev libxinerama-dev libxi-dev libxcursor-dev libgl-dev \
        fonts-dejavu-core \
    && rm -rf /var/lib/apt/lists/*

# Official Zig release, checked against the checksum from
# https://ziglang.org/download/index.json.
ARG ZIG_VERSION=0.16.0
ARG ZIG_SHA256=70e49664a74374b48b51e6f3fdfbf437f6395d42509050588bd49abe52ba3d00
RUN curl -fsSL -o /tmp/zig.tar.xz "https://ziglang.org/download/${ZIG_VERSION}/zig-x86_64-linux-${ZIG_VERSION}.tar.xz" \
    && echo "${ZIG_SHA256}  /tmp/zig.tar.xz" | sha256sum -c - \
    && mkdir /opt/zig && tar -xJf /tmp/zig.tar.xz -C /opt/zig --strip-components=1 \
    && rm /tmp/zig.tar.xz
ENV PATH="/opt/zig:${PATH}"
