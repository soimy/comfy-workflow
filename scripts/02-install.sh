#!/usr/bin/env bash
# 在 distrobox 容器 (comfyui) 内执行：安装 ComfyUI + 放大工作流所需组件
# 用法: bash /var/home/sym/Repo/comfyui/scripts/02-install.sh
set -euo pipefail

REPO="${REPO:-/var/home/sym/Repo/comfyui}"
COMFY="$REPO/ComfyUI"
VENV="$COMFY/.venv"

echo "==> [1/5] 安装系统依赖"
sudo apt-get update -qq
sudo apt-get install -y -qq git python3.12 python3.12-venv python3-pip ffmpeg aria2 >/dev/null

echo "==> [2/5] 克隆 ComfyUI"
if [ ! -d "$COMFY/.git" ]; then
  git clone --depth 1 https://github.com/comfyanonymous/ComfyUI.git "$COMFY"
fi
mkdir -p "$COMFY/models/.gitkeep" 2>/dev/null || true
touch "$COMFY/models/.gitkeep"

echo "==> [3/5] 创建 venv 并安装 PyTorch (cu128, 支持 RTX 5080 / sm_120)"
python3.12 -m venv "$VENV"
source "$VENV/bin/activate"
pip install -q --upgrade pip wheel
pip install -q torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu128

echo "==> [4/5] 安装 ComfyUI 依赖与自定义节点"
pip install -q -r "$COMFY/requirements.txt"
CUSTOM="$COMFY/custom_nodes"
[ -d "$CUSTOM/ComfyUI-Manager" ] || git clone --depth 1 https://github.com/ltdrdata/ComfyUI-Manager.git "$CUSTOM/ComfyUI-Manager"
[ -d "$CUSTOM/ComfyUI-SUPIR" ]   || git clone --depth 1 https://github.com/kijai/ComfyUI-SUPIR.git   "$CUSTOM/ComfyUI-SUPIR"
[ -d "$CUSTOM/ComfyUI_UltimateSDUpscale" ] || git clone --depth 1 https://github.com/ssitu/ComfyUI_UltimateSDUpscale.git "$CUSTOM/ComfyUI_UltimateSDUpscale"
[ -d "$CUSTOM/ComfyUI-TiledDiffusion" ]    || git clone --depth 1 https://github.com/shiimizu/ComfyUI-TiledDiffusion.git    "$CUSTOM/ComfyUI-TiledDiffusion"
pip install -q -r "$CUSTOM/ComfyUI-SUPIR/requirements.txt"
# SUPIR 节点按 transformers v4 的 CLIPTextModel.text_model 结构访问，v5 会崩
pip install -q "transformers<5"
pip install -q -r "$CUSTOM/ComfyUI-Manager/requirements.txt"

echo "==> [5/5] 安装 huggingface 下载工具"
pip install -q "huggingface_hub[cli]" hf_transfer

echo "安装完成。下一步: bash $REPO/scripts/03-download-models.sh"
