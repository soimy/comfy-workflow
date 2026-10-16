#!/usr/bin/env bash
# 在 distrobox 容器内执行：下载 SUPIR + Flux Tile 放大工作流所需模型（约 30GB）
# 可选参数: bash 03-download-models.sh [all|supir|flux]
set -euo pipefail

REPO="${REPO:-/var/home/sym/Repo/comfyui}"
MODELS="$REPO/ComfyUI/models"
export HF_XET_HIGH_PERFORMANCE=1
source "$REPO/ComfyUI/.venv/bin/activate"

pick=${1:-all}
dl() { # dl <repo_id> <file> <dest_dir>
  echo ">>> $1/$2 -> models/$3/"
  hf download "$1" "$2" --local-dir "$MODELS/$3"
}

case "$pick" in
  all|flux)
    # Flux.1-dev fp8 去噪模型 + 文本编码器 + VAE
    dl Comfy-Org/flux1-dev            flux1-dev-fp8.safetensors        diffusion_models
    dl comfyanonymous/flux_text_encoders clip_l.safetensors            text_encoders
    dl comfyanonymous/flux_text_encoders t5xxl_fp8_e4m3fn.safetensors   text_encoders
    dl black-forest-labs/FLUX.1-schnell  ae.safetensors                vae
    ;;
esac

case "$pick" in
  all|supir)
    # SUPIR 检查点 + SDXL base（SUPIR 走 SDXL 采样管线）+ 通用放大模型
    dl kijai/SUPIR                    SUPIR-v0q.ckpt                   SUPIR
    dl stabilityai/stable-diffusion-xl-base-1.0 sd_xl_base_1.0.safetensors checkpoints
    dl kijai/SUPIR                    SUPIR_v0_general_v1.yaml         SUPIR
    dl Comfy-Org/Wan_2.1_ComfyUI_repackaged 4x-UltraSharp.pth upscale_models 2>/dev/null \
      || dl lavinal712/UltraSharp-upscale-model 4x-UltraSharp.pth upscale_models
    ;;
esac

echo "全部模型下载完成。"
