# Tdarr Node — CUDA 12.4 + FFmpeg 7.0.3 + NVENC/NVDEC

This repository builds a custom **Tdarr Node** image with:

- CUDA **12.4.1**
- FFmpeg **7.0.3**
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
- CUDA filters  
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

## 🐳 Run Example (Docker)

```bash
docker run -d \
  --gpus all \
  -e NVIDIA_VISIBLE_DEVICES=all \
  -e NVIDIA_DRIVER_CAPABILITIES=compute,video,utility \
  -p 8267:8267 \
  ghcr.io/<user>/tdarr-node-cuda124:latest