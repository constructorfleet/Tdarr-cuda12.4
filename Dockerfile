###############################
# Stage 1: Build FFmpeg with NVENC on CUDA 12.4
###############################
FROM nvidia/cuda:12.4.1-devel-ubuntu22.04 AS ffmpeg-build

ENV DEBIAN_FRONTEND=noninteractive

# Core build deps + codec dev libs
RUN apt-get update && apt-get install -y --no-install-recommends \
    autoconf \
    automake \
    build-essential \
    cmake \
    git \
    pkg-config \
    yasm \
    nasm \
    libtool \
    libssl-dev \
    libx264-dev \
    libvpx-dev \
    libfdk-aac-dev \
    libass-dev \
    libfreetype6-dev \
    libfribidi-dev \
    libfontconfig1-dev \
    libvorbis-dev \
    libopus-dev \
    libxml2-dev \
    libdrm-dev \
    libzimg-dev \
    libxvidcore-dev \
    libshine-dev \
    zlib1g-dev \
    liblzma-dev \
    libicu-dev \
    libzstd-dev \
    ca-certificates \
    curl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /tmp

RUN which pkg-config
RUN pkg-config --debug --print-errors --cflags libxml-2.0

# Build x265 manually because Ubuntu packages suck
RUN git clone https://github.com/videolan/x265.git && \
    cd x265/build/linux && \
    cmake -DENABLE_SHARED=ON ../../source && \
    make -j"$(nproc)" && \
    make install
# Install NVENC/NVDEC headers
RUN git clone https://github.com/FFmpeg/nv-codec-headers.git && \
    cd nv-codec-headers && \
    make install

# Get FFmpeg source
ARG FFMPEG_VERSION=7.0.3
RUN curl -L https://github.com/FFmpeg/FFmpeg/archive/refs/tags/n${FFMPEG_VERSION}.tar.gz -o ffmpeg.tar.gz && \
    tar xf ffmpeg.tar.gz && \
    rm ffmpeg.tar.gz && \
    mv FFmpeg-n${FFMPEG_VERSION} ffmpeg

WORKDIR /tmp/ffmpeg

# Build FFmpeg with CUDA/NVENC/NVDEC and full Tdarr audio/subtitle support
RUN ./configure \
    --prefix=/usr/local \
    # --pkg-config-flags="--static" \
    --extra-cflags="-I/usr/local/cuda/include" \
    --extra-ldflags="-L/usr/local/cuda/lib64" \
    --extra-libs="-lpthread -lm" \
    --enable-gpl \
    --enable-version3 \
    --enable-nonfree \
    --enable-libx264 \
    --enable-libx265 \
    --enable-libvpx \
    --enable-libfdk-aac \
    --enable-libass \
    --enable-libfreetype \
    --enable-fontconfig \
    --enable-libfribidi \
    --enable-libvorbis \
    --enable-libopus \
    --enable-libxml2 \
    --enable-libzimg \
    --enable-libxvid \
    --enable-libshine \
    --enable-cuda \
    --enable-cuvid \
    --enable-nvenc \
    --enable-nvdec \
    --enable-ffnvcodec \
    --enable-libdrm \
    --enable-openssl \
    --disable-debug \
    --disable-doc \
    && make -j"$(nproc)" && \
    make install && \
    strip /usr/local/bin/ffmpeg /usr/local/bin/ffprobe

###############################
# Stage 2: Grab Tdarr Node from official image + tools
###############################
FROM ghcr.io/haveagitgat/tdarr_node:latest AS tdarr-base

RUN apt-get update && apt-get install -y wget && rm -rf /var/lib/apt/lists/*

ARG TARGETARCH
ARG DOVI_TOOL_VERSION=2.3.2
ARG HDR10PLUS_TOOL_VERSION=1.7.2

# Dolby Vision tools
RUN case "${TARGETARCH:-amd64}" in \
        amd64) TOOL_ARCH=x86_64 ;; \
        arm64) TOOL_ARCH=aarch64 ;; \
        *) echo "Unsupported TARGETARCH: ${TARGETARCH:-unknown}" >&2; exit 1 ;; \
    esac && \
    wget -O - "https://github.com/quietvoid/dovi_tool/releases/download/${DOVI_TOOL_VERSION}/dovi_tool-${DOVI_TOOL_VERSION}-${TOOL_ARCH}-unknown-linux-musl.tar.gz" \
        | tar -zx -C /usr/local/bin/

# HDR10+ tools
RUN case "${TARGETARCH:-amd64}" in \
        amd64) TOOL_ARCH=x86_64 ;; \
        arm64) TOOL_ARCH=aarch64 ;; \
        *) echo "Unsupported TARGETARCH: ${TARGETARCH:-unknown}" >&2; exit 1 ;; \
    esac && \
    wget -O - "https://github.com/quietvoid/hdr10plus_tool/releases/download/${HDR10PLUS_TOOL_VERSION}/hdr10plus_tool-${HDR10PLUS_TOOL_VERSION}-${TOOL_ARCH}-unknown-linux-musl.tar.gz" \
        | tar -zx -C /usr/local/bin/

###############################
# Stage 3: Final runtime image
###############################
FROM nvidia/cuda:12.5.1-runtime-ubuntu24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    tzdata \
    curl \
    wget \
    jq \
    tini \
    mediainfo \
    libfribidi0 \
    && rm -rf /var/lib/apt/lists/*

ENV S6_BEHAVIOUR_IF_STAGE2_FAILS=2
ENV TDARR_SKIP_FFMPEG_SETUP=true

# Bring over s6 init, Tdarr node, tools, node runtime
COPY --from=tdarr-base /init /init
COPY --from=tdarr-base /etc /etc
COPY --from=tdarr-base /app /app
COPY --from=tdarr-base /var /var
COPY --from=tdarr-base /usr/bin /usr/bin
COPY --from=tdarr-base /usr/lib/node_modules /usr/lib/node_modules
# s6-overlay installs its real binaries under /package; /usr/bin/s6-* are symlinks into it
COPY --from=tdarr-base /package /package
# /command is also used by s6-overlay for its run scripts
COPY --from=tdarr-base /command /command
COPY --from=tdarr-base /usr/local/bin/dovi_tool /usr/local/bin/dovi_tool
COPY --from=tdarr-base /usr/local/bin/hdr10plus_tool /usr/local/bin/hdr10plus_tool

# Copy ffmpeg + libs
COPY --from=ffmpeg-build /usr/local/bin/ffmpeg /usr/local/bin/
COPY --from=ffmpeg-build /usr/local/bin/ffprobe /usr/local/bin/
COPY --from=ffmpeg-build /usr/local/lib/ /usr/local/lib/
COPY --from=ffmpeg-build /usr/lib/*-linux-gnu/libdrm.so.2* /usr/local/lib/
COPY --from=ffmpeg-build /usr/lib/*-linux-gnu/libass.so.9* /usr/local/lib/
COPY --from=ffmpeg-build /usr/lib/*-linux-gnu/libzimg.so.2* /usr/local/lib/
COPY --from=ffmpeg-build /usr/lib/*-linux-gnu/libfontconfig.so.1* /usr/local/lib/
COPY --from=ffmpeg-build /usr/lib/*-linux-gnu/libfreetype.so.6* /usr/local/lib/
COPY --from=ffmpeg-build /usr/lib/*-linux-gnu/libharfbuzz.so.0* /usr/local/lib/
COPY --from=ffmpeg-build /usr/lib/*-linux-gnu/libglib-2.0.so.0* /usr/local/lib/
COPY --from=ffmpeg-build /usr/lib/*-linux-gnu/libgraphite2.so.3* /usr/local/lib/
COPY --from=ffmpeg-build /usr/lib/*-linux-gnu/libxml2.so.2* /usr/local/lib/
COPY --from=ffmpeg-build /usr/lib/*-linux-gnu/libvpx.so.7* /usr/local/lib/
COPY --from=ffmpeg-build /usr/lib/*-linux-gnu/libfdk-aac.so.2* /usr/local/lib/
COPY --from=ffmpeg-build /usr/lib/*-linux-gnu/libexpat.so.1* /usr/local/lib/
COPY --from=ffmpeg-build /usr/lib/*-linux-gnu/libpng16.so.16* /usr/local/lib/
COPY --from=ffmpeg-build /usr/lib/*-linux-gnu/libicuuc.so.70* /usr/local/lib/
COPY --from=ffmpeg-build /usr/lib/*-linux-gnu/libicudata.so.70* /usr/local/lib/
COPY --from=ffmpeg-build /usr/lib/*-linux-gnu/libicui18n.so.70* /usr/local/lib/
COPY --from=ffmpeg-build /usr/lib/*-linux-gnu/libogg.so.0* /usr/local/lib/
COPY --from=ffmpeg-build /usr/lib/*-linux-gnu/libopus.so.0* /usr/local/lib/
COPY --from=ffmpeg-build /usr/lib/*-linux-gnu/libshine.so.3* /usr/local/lib/
COPY --from=ffmpeg-build /usr/lib/*-linux-gnu/libvorbis.so.0* /usr/local/lib/
COPY --from=ffmpeg-build /usr/lib/*-linux-gnu/libvorbisenc.so.2* /usr/local/lib/
COPY --from=ffmpeg-build /usr/lib/*-linux-gnu/libx264.so.163* /usr/local/lib/
COPY --from=ffmpeg-build /usr/lib/*-linux-gnu/libxvidcore.so.4* /usr/local/lib/

RUN mv /etc/cont-init.d/03-setup-ffmpeg /usr/local/bin/tdarr-setup-ffmpeg.orig && \
    printf '%s\n' \
        '#!/usr/bin/with-contenv bash' \
        'if [ "${TDARR_SKIP_FFMPEG_SETUP:-false}" = "true" ]; then' \
        '    echo "Skipping Tdarr FFmpeg setup; keeping custom binaries"' \
        '    exit 0' \
        'fi' \
        'exec /usr/local/bin/tdarr-setup-ffmpeg.orig "$@"' \
        > /etc/cont-init.d/03-setup-ffmpeg && \
    chmod +x /etc/cont-init.d/03-setup-ffmpeg /usr/local/bin/tdarr-setup-ffmpeg.orig && \
    chmod +rx /usr/local/bin/dovi_tool /usr/local/bin/hdr10plus_tool /usr/lib/node_modules && \
    ln -s /usr/local/bin/ffmpeg /usr/local/bin/tdarr-ffmpeg && \
    ln -s /usr/local/bin/ffprobe /usr/local/bin/tdarr-ffprobe && \
    ldconfig

ENV NVIDIA_VISIBLE_DEVICES=all
ENV NVIDIA_DRIVER_CAPABILITIES=compute,video,utility

WORKDIR /app

ENTRYPOINT ["/init"]
