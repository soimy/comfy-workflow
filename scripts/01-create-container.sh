#!/usr/bin/env bash
# 在宿主机 (Bazzite) 上执行：创建 distrobox 容器 comfyui
# RTX 5080 (Blackwell/sm_120) 需要 PyTorch cu128 wheel，容器本体用 Ubuntu 24.04 即可，
# CUDA 运行时由 torch 自带，仅透传驱动 (--nvidia)。
set -euo pipefail

NAME=comfyui
IMAGE=ubuntu:24.04
REPO="${REPO:-$HOME/Repo/comfyui}"

if distrobox list 2>/dev/null | grep -qw "$NAME"; then
  echo "容器 $NAME 已存在，跳过创建"
  exit 0
fi

distrobox create \
  --name "$NAME" \
  --image "$IMAGE" \
  --nvidia \
  --home "$HOME/.distrobox-home/comfyui" \
  --additional-flags "--device /dev/dri" \
  -Y

echo "容器创建完成。进入方式: distrobox enter $NAME"
echo "下一步: $REPO/scripts/02-install.sh"
