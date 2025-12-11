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
    libzimg-dev \
    libxvidcore-dev \
    libshine-dev \
    zlib1g-dev \
    ca-certificates \
    curl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /tmp

RUN echo "pkg-config search paths:" && pkg-config --variable pc_path pkg-config

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
RUN curl -L https://ffmpeg.org/releases/ffmpeg-${FFMPEG_VERSION}.tar.xz -o ffmpeg.tar.xz && \
    tar xf ffmpeg.tar.xz && \
    rm ffmpeg.tar.xz && \
    mv ffmpeg-${FFMPEG_VERSION} ffmpeg

WORKDIR /tmp/ffmpeg

# Build FFmpeg with CUDA/NVENC/NVDEC and full Tdarr audio/subtitle support
RUN ./configure \
    --prefix=/usr/local \
    --pkg-config-flags="--static" \
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

RUN apt-get update && apt-get install -y wget jq && rm -rf /var/lib/apt/lists/*

# Dolby Vision tools
RUN URL=$(wget -q -O - https://api.github.com/repos/quietvoid/dovi_tool/releases/latest | jq -r '.assets[] | select(.browser_download_url | endswith("x86_64-unknown-linux-musl.tar.gz"))| .browser_download_url') && \
    wget -O - $URL \
        | tar -zx -C /usr/local/bin/

# HDR10+ tools
RUN URL=$(wget -q -O - https://api.github.com/repos/quietvoid/hdr10plus_tool/releases/latest| jq -r '.assets[] | select(.browser_download_url | endswith("x86_64-unknown-linux-musl.tar.gz"))| .browser_download_url') && \
    wget -O - $URL \
        | tar -zx -C /usr/local/bin/

###############################
# Stage 3: Final runtime image
###############################
FROM nvidia/cuda:12.4.1-runtime-ubuntu22.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    tzdata \
    curl \
    wget \
    tini \
    mediainfo \
    && rm -rf /var/lib/apt/lists/*

ENV S6_BEHAVIOUR_IF_STAGE2_FAILS=2

# Bring over s6 init, Tdarr node, tools, node runtime
COPY --from=tdarr-base /init /init
COPY --from=tdarr-base /etc /etc
COPY --from=tdarr-base /app /app
COPY --from=tdarr-base /var /var
COPY --from=tdarr-base /usr/bin/node /usr/bin/node
COPY --from=tdarr-base /usr/lib/node_modules /usr/lib/node_modules
COPY --from=tdarr-base /usr/local/bin/dovi_tool /usr/local/bin/dovi_tool
COPY --from=tdarr-base /usr/local/bin/hdr10plus_tool /usr/local/bin/hdr10plus_tool

# Copy ffmpeg + libs
COPY --from=ffmpeg-build /usr/local/bin/ffmpeg /usr/local/bin/
COPY --from=ffmpeg-build /usr/local/bin/ffprobe /usr/local/bin/
COPY --from=ffmpeg-build /usr/local/lib/ /usr/local/lib/

RUN chmod +rx /usr/local/bin/dovi_tool /usr/local/bin/hdr10plus_tool /usr/lib/node_modules && \
    ln -s /usr/local/bin/ffmpeg /usr/local/bin/tdarr-ffmpeg && \
    ldconfig

ENV NVIDIA_VISIBLE_DEVICES=all
ENV NVIDIA_DRIVER_CAPABILITIES=compute,video,utility

WORKDIR /app

ENTRYPOINT ["/init"]
