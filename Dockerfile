ARG TDARR_TAG=3.10.00
###############################
# Stage 1: Build FFmpeg with NVENC on CUDA 12.4 / Ubuntu 22.04
###############################
FROM nvidia/cuda:12.4.1-devel-ubuntu22.04 AS ffmpeg-build
ENV DEBIAN_FRONTEND=noninteractive \
    PKG_CONFIG_PATH=/usr/local/lib/pkgconfig
RUN apt-get update && apt-get install -y --no-install-recommends \
    autoconf \
    automake \
    build-essential \
    ca-certificates \
    cmake \
    curl \
    git \
    libass-dev \
    libdrm-dev \
    libfdk-aac-dev \
    libfontconfig1-dev \
    libfreetype6-dev \
    libfribidi-dev \
    libicu-dev \
    liblzma-dev \
    libopus-dev \
    libshine-dev \
    libssl-dev \
    libtool \
    libvorbis-dev \
    libvpx-dev \
    libx264-dev \
    libxml2-dev \
    libxvidcore-dev \
    libzimg-dev \
    libzstd-dev \
    nasm \
    pkg-config \
    yasm \
    zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /tmp
# Build x265 manually because Ubuntu packages suck
RUN git clone https://github.com/videolan/x265.git && \
    cd x265/build/linux && \
    cmake -DENABLE_SHARED=ON ../../source && \
    make -j"$(nproc)" && \
    make install
ARG NVCODEC_HEADERS_VERSION=n12.2.72.0
RUN git clone --branch "${NVCODEC_HEADERS_VERSION}" --depth 1 \
      https://github.com/FFmpeg/nv-codec-headers.git && \
    make -C nv-codec-headers install
ARG FFMPEG_VERSION=9.1
RUN curl --fail --location --show-error \
      "https://github.com/FFmpeg/FFmpeg/archive/refs/tags/n${FFMPEG_VERSION}.tar.gz" \
      --output ffmpeg.tar.gz && \
    tar --extract --file ffmpeg.tar.gz && \
    mv "FFmpeg-n${FFMPEG_VERSION}" ffmpeg && \
    rm ffmpeg.tar.gz
WORKDIR /tmp/ffmpeg
RUN ./configure \
    --prefix=/usr/local \
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
    --enable-openssl \
    --disable-debug \
    --disable-doc && \
    make -j"$(nproc)" && \
    make install && \
    strip /usr/local/bin/ffmpeg /usr/local/bin/ffprobe
###############################
# Stage 2: CUDA runtime files
###############################
FROM nvidia/cuda:12.4.1-runtime-ubuntu22.04 AS cuda-runtime
###############################
# Stage 3: Official Tdarr Node plus extra HDR tools
###############################
FROM ghcr.io/haveagitgat/tdarr_node:${TDARR_TAG} AS tdarr-base
USER root
# Refresh distro packages to pick up security fixes; linux-libc-dev is a
# header-only package with a large unfixable CVE backlog and is not needed at
# runtime. Do not use autoremove: it also drops runtime libraries used by Tdarr.
RUN apt-get update && apt-get -y upgrade && apt-get install -y --no-install-recommends \
    ca-certificates \
    wget \
    && apt-get remove -y linux-libc-dev \
    && rm -rf /var/lib/apt/lists/*
ARG TARGETARCH
ARG DOVI_TOOL_VERSION=2.3.4
ARG HDR10PLUS_TOOL_VERSION=1.7.2
ARG ADM_ZIP_VERSION=0.6.1
ARG AXIOS_VERSION=0.34.0
RUN case "${TARGETARCH:-amd64}" in \
      amd64) TOOL_ARCH=x86_64 ;; \
      arm64) TOOL_ARCH=aarch64 ;; \
      *) echo "Unsupported TARGETARCH: ${TARGETARCH:-unknown}" >&2; exit 1 ;; \
    esac && \
    wget -qO- \
      "https://github.com/quietvoid/dovi_tool/releases/download/${DOVI_TOOL_VERSION}/dovi_tool-${DOVI_TOOL_VERSION}-${TOOL_ARCH}-unknown-linux-musl.tar.gz" \
      | tar -xz -C /usr/local/bin/ && \
    wget -qO- \
      "https://github.com/quietvoid/hdr10plus_tool/releases/download/${HDR10PLUS_TOOL_VERSION}/hdr10plus_tool-${HDR10PLUS_TOOL_VERSION}-${TOOL_ARCH}-unknown-linux-musl.tar.gz" \
      | tar -xz -C /usr/local/bin/
# Tdarr vendors stripped Node modules. Running `npm install` directly in
# /app/Tdarr_Node prunes the other vendored packages, so install axios into a
# temporary prefix and copy its full dependency tree into place instead.
RUN set -eu; \
    dir="/app/Tdarr_Node/node_modules/adm-zip"; \
    rm -rf "${dir}" && mkdir -p "${dir}" && \
    wget -qO /tmp/adm-zip.tgz \
      "https://registry.npmjs.org/adm-zip/-/adm-zip-${ADM_ZIP_VERSION}.tgz" && \
    tar -xzf /tmp/adm-zip.tgz --strip-components=1 -C "${dir}" && \
    rm -f /tmp/adm-zip.tgz; \
    npm install --prefix /tmp/axios-fix --no-audit --no-fund \
      "axios@${AXIOS_VERSION}" >/dev/null && \
    cp -a /tmp/axios-fix/node_modules/. /app/Tdarr_Node/node_modules/ && \
    rm -rf /tmp/axios-fix
# CVE-2026-43893: block CR/LF/NUL in ExifTool arguments until upstream Tdarr
# ships exiftool-vendored >= 35.19.0. This is the renderer-side defense from
# the advisory; the vendored package version is intentionally left unchanged.
RUN python3 -c 'from pathlib import Path; p=Path("/app/Tdarr_Node/node_modules/exiftool-vendored/index.js"); s=p.read_text(); old="      static renderCommand(args) {\n        return [...args, \"-ignoreMinorErrors\", \"-execute\", \"\"].join(\"\\n\");\n      }"; new="      static renderCommand(args) {\n        for (const arg of args) {\n          if (typeof arg === \"string\" && /[\\r\\n\\0]/.test(arg)) throw new Error(\"Unsafe control character in ExifTool argument\");\n        }\n        return [...args, \"-ignoreMinorErrors\", \"-execute\", \"\"].join(\"\\n\");\n      }"; assert old in s, "ExifTool patch point not found"; p.write_text(s.replace(old, new, 1))'
# pip's vendoring metadata still lists setuptools 70.3.0 even though no
# setuptools code is vendored. Remove the stale entry so scanners stop flagging
# CVE-2025-47273; this metadata is only used by pip's own tests/tooling.
RUN python3 -c 'import json; from pathlib import Path; base=Path("/home/Tdarr/.local/share/pipx/shared/lib/python3.12/site-packages/pip/_vendor"); v=base/"vendor.txt"; v.write_text("".join(l for l in v.read_text().splitlines(True) if not l.startswith("setuptools=="))); b=base/"bom.cdx.json"; d=json.loads(b.read_text()); purl="pkg:pypi/setuptools@70.3.0"; d["components"]=[c for c in d.get("components",[]) if c.get("name")!="setuptools"]; d["dependencies"]=[x for x in d.get("dependencies",[]) if x.get("ref")!=purl]; [x["dependsOn"].remove(purl) for x in d.get("dependencies",[]) if purl in x.get("dependsOn",[])]; b.write_text(json.dumps(d,indent=2)+"\n")'
###############################
# Stage 4: Final runtime image
#
# Inherit Tdarr instead of copying /usr/bin, /etc, and /var into a different
# Ubuntu release. This keeps HandBrakeCLI, mkvpropedit, and their shared
# libraries from the same package/runtime ecosystem.
###############################
FROM tdarr-base AS final
USER root
ENV DEBIAN_FRONTEND=noninteractive \
    NVIDIA_VISIBLE_DEVICES=all \
    NVIDIA_DRIVER_CAPABILITIES=compute,video,utility \
    TDARR_SKIP_FFMPEG_SETUP=true
# CUDA user-space runtime needed by the custom FFmpeg build. The host driver
# still supplies libcuda/libnvidia-encode through the NVIDIA container runtime.
COPY --from=cuda-runtime /usr/local/cuda-12.4/ /usr/local/cuda-12.4/
COPY --from=ffmpeg-build /usr/local/bin/ffmpeg /usr/local/bin/ffmpeg
COPY --from=ffmpeg-build /usr/local/bin/ffprobe /usr/local/bin/ffprobe
COPY --from=ffmpeg-build /usr/local/lib/ /usr/local/lib/
# Libraries enabled in the Ubuntu 22.04 FFmpeg build which are not installed
# under /usr/local by their distro packages.
COPY --from=ffmpeg-build /usr/lib/*-linux-gnu/libass.so.9* /usr/local/lib/
COPY --from=ffmpeg-build /usr/lib/*-linux-gnu/libdrm.so.2* /usr/local/lib/
COPY --from=ffmpeg-build /usr/lib/*-linux-gnu/libexpat.so.1* /usr/local/lib/
COPY --from=ffmpeg-build /usr/lib/*-linux-gnu/libfdk-aac.so.2* /usr/local/lib/
COPY --from=ffmpeg-build /usr/lib/*-linux-gnu/libfontconfig.so.1* /usr/local/lib/
COPY --from=ffmpeg-build /usr/lib/*-linux-gnu/libfreetype.so.6* /usr/local/lib/
COPY --from=ffmpeg-build /usr/lib/*-linux-gnu/libfribidi.so.0* /usr/local/lib/
COPY --from=ffmpeg-build /usr/lib/*-linux-gnu/libglib-2.0.so.0* /usr/local/lib/
COPY --from=ffmpeg-build /usr/lib/*-linux-gnu/libgraphite2.so.3* /usr/local/lib/
COPY --from=ffmpeg-build /usr/lib/*-linux-gnu/libharfbuzz.so.0* /usr/local/lib/
COPY --from=ffmpeg-build /usr/lib/*-linux-gnu/libicudata.so.70* /usr/local/lib/
COPY --from=ffmpeg-build /usr/lib/*-linux-gnu/libicui18n.so.70* /usr/local/lib/
COPY --from=ffmpeg-build /usr/lib/*-linux-gnu/libicuuc.so.70* /usr/local/lib/
COPY --from=ffmpeg-build /usr/lib/*-linux-gnu/libogg.so.0* /usr/local/lib/
COPY --from=ffmpeg-build /usr/lib/*-linux-gnu/libopus.so.0* /usr/local/lib/
COPY --from=ffmpeg-build /usr/lib/*-linux-gnu/libpcre.so.3* /usr/local/lib/
COPY --from=ffmpeg-build /usr/lib/*-linux-gnu/libpng16.so.16* /usr/local/lib/
COPY --from=ffmpeg-build /usr/lib/*-linux-gnu/libshine.so.3* /usr/local/lib/
COPY --from=ffmpeg-build /usr/lib/*-linux-gnu/libvorbis.so.0* /usr/local/lib/
COPY --from=ffmpeg-build /usr/lib/*-linux-gnu/libvorbisenc.so.2* /usr/local/lib/
COPY --from=ffmpeg-build /usr/lib/*-linux-gnu/libvpx.so.7* /usr/local/lib/
COPY --from=ffmpeg-build /usr/lib/*-linux-gnu/libx264.so.163* /usr/local/lib/
COPY --from=ffmpeg-build /usr/lib/*-linux-gnu/libxvidcore.so.4* /usr/local/lib/
COPY --from=ffmpeg-build /usr/lib/*-linux-gnu/libxml2.so.2* /usr/local/lib/
COPY --from=ffmpeg-build /usr/lib/*-linux-gnu/libzimg.so.2* /usr/local/lib/
COPY --from=tdarr-base /usr/local/bin/dovi_tool /usr/local/bin/dovi_tool
COPY --from=tdarr-base /usr/local/bin/hdr10plus_tool /usr/local/bin/hdr10plus_tool
RUN ln -sfn /usr/local/cuda-12.4 /usr/local/cuda && \
    rm -f /usr/local/bin/tdarr-ffmpeg /usr/local/bin/tdarr-ffprobe && \
    ln -s /usr/local/bin/ffmpeg /usr/local/bin/tdarr-ffmpeg && \
    ln -s /usr/local/bin/ffprobe /usr/local/bin/tdarr-ffprobe && \
    chmod 0755 /usr/local/bin/ffmpeg /usr/local/bin/ffprobe \
      /usr/local/bin/dovi_tool /usr/local/bin/hdr10plus_tool && \
    ldconfig && \
    ffmpeg -hide_banner -version && \
    ffmpeg -hide_banner -encoders | grep -q hevc_nvenc && \
    HandBrakeCLI --version && \
    mkvpropedit --version && \
    dovi_tool --version && \
    hdr10plus_tool --version && \
    ! ldd "$(command -v HandBrakeCLI)" | grep -q 'not found' && \
    ! ldd "$(command -v mkvpropedit)" | grep -q 'not found'
# Preserve the official image's /init entrypoint and service layout.
WORKDIR /app
ENTRYPOINT ["/init"]
