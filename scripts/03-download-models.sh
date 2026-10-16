#!/usr/bin/env bash
# 在 distrobox 容器内执行：下载 SUPIR + Flux Tile 放大工作流所需模型（约 30GB）
# 可选参数: bash 03-download-models.sh [all|supir|flux]
set -euo pipefail

REPO="${REPO:-/var/home/sym/Repo/comfyui}"
MODELS="$REPO/ComfyUI/models"
export HF_XET_HIGH_PERFORMANCE=1
# 禁用 Xet（CAS 传输在国内网络常报 I/O 错误），并优先走 hf-mirror 镜像
export HF_HUB_DISABLE_XET=1
if [ -z "${HF_ENDPOINT:-}" ]; then
  if curl -s -o /dev/null --max-time 8 -r 0-1048575 -L https://huggingface.co; then
    export HF_ENDPOINT=https://huggingface.co
  else
    export HF_ENDPOINT=https://hf-mirror.com
  fi
fi
echo "HF_ENDPOINT=$HF_ENDPOINT"
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
    dl black-forest-labs/FLUX.1-schnell  ae.safetensors                vae 2>/dev/null \
      || dl sirorable/flux-ae-vae ae.safetensors vae
    ;;
esac

case "$pick" in
  all|supir)
    # SUPIR 检查点（fp16 pruned 版，免下 SDXL base 单文件省 6.9GB）
    # SUPIR_model_loader_v2 只需 SUPIR 权重，底模 SDXL 由 CheckpointLoaderSimple 加载
    dl Kijai/SUPIR_pruned             SUPIR-v0Q_fp16.safetensors       SUPIR
    dl camenduru/SUPIR                SUPIR-v0Q.ckpt                   SUPIR 2>/dev/null || true
    dl camenduru/SUPIR                sd_xl_base_1.0_0.9vae.safetensors checkpoints
    # （yaml 配置已随 ComfyUI-SUPIR 仓库内置于 options/，无需单独下载）
    dl philz1337x/upscaler 4x-UltraSharp.pth upscale_models 2>/dev/null \
      || curl -fsSL -o "$MODELS/upscale_models/4x-UltraSharp.pth" https://huggingface.co/lokCX/4x-Ultrasharp/resolve/main/4x-UltraSharp.pth
    ;;
esac

echo "全部模型下载完成。"
