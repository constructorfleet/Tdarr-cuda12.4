# Tdarr Node — CUDA 12.4 + FFmpeg 9.1 + NVENC/NVDEC

This repository builds a custom **Tdarr Node** image with:

- CUDA **12.4.1**
- FFmpeg **9.1**
- Full NVENC/NVDEC acceleration
- Hardened audio/subtitle codec support
- Dolby Vision & HDR10+ tools
- Correct s6-overlay integration (required for Tdarr)
- Stable behavior under Docker Swarm GPU deployments

This image is designed to avoid the common runtime failures caused by:

- Jellyfin’s patched FFmpeg builds  
- CUDA/NVIDIA ABI mismatches  
- NCT legacy injection mode  
- OverlayFS shims being lost under Docker Swarm  
- `cuInit failed: no CUDA-capable device` errors  

---

## 🚀 Features

### ✔ FFmpeg with complete CUDA/NVENC support  
Includes:

- H.264 / HEVC NVENC encoders  
- NVDEC GPU decoders  
- Proper `nv-codec-headers` integration  

### ✔ Full Tdarr audio/subtitle support  
Built with:

- libfdk-aac  
- libopus  
- libvorbis  
- libxvid  
- libshine  
- libass + fribidi + fontconfig  
- libzimg  
- libxml2  

### ✔ HDR Tools  
Installed from latest releases:

- `dovi_tool`  
- `hdr10plus_tool`  

### ✔ S6-overlay init  
The Tdarr Node requires the `/init` entrypoint and s6 service tree.  
This image preserves them intact.

---

## 🔒 Vulnerability reduction

The upstream Tdarr node base image carries a large Ubuntu CVE backlog, mostly
from `linux-libc-dev` plus vulnerable vendored Node modules. This build:

- Starts from Tdarr **3.10.00** instead of **2.95.01**.
- Runs `apt-get upgrade` to pick up distro security fixes.
- Removes `linux-libc-dev` (header-only, not needed at runtime — no `autoremove`,
  which would drop runtime libraries).
- Replaces vendored `adm-zip` and `axios` in place with patched releases
  (`0.6.1` and `0.34.0`, plus axios's runtime dependencies). `npm install` is
  deliberately avoided because it prunes Tdarr's other stripped vendored
  modules.
- Applies the advisory's renderer-side control-character guard to the vendored
  `exiftool-vendored` package (CVE-2026-43893) until Tdarr ships a newer copy.
- Removes pip's stale `setuptools 70.3.0` vendor metadata (no setuptools code is
  actually vendored) to clear the false-positive CVE-2025-47273 finding.
- Builds FFmpeg **9.1** instead of **7.0.3**, picking up the upstream security
  fixes from the 8.x/9.x branches.

A local Trivy `HIGH,CRITICAL` scan drops from **1722** findings on the original
`2.95.01` base to **48** on the rebuilt image. All 48 residual findings come
from compiled Go binaries inside the upstream Tdarr image (47) and the vendored
`exiftool-vendored` version string (1); they cannot be removed without upstream
rebuilds. The exiftool argument-injection path is mitigated in this image even
though the scanner still sees the old package version. CI runs a report-only
Trivy scan on every publish so new regressions are visible.

---

## 🐳 Run Example (Docker)

```bash
docker run -d \
  --gpus all \
  -e NVIDIA_VISIBLE_DEVICES=all \
  -e NVIDIA_DRIVER_CAPABILITIES=compute,video,utility \
  -p 8267:8267 \
  ghcr.io/<user>/tdarr-node-cuda124:latest