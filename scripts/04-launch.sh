#!/usr/bin/env bash
# 在宿主机执行：启动容器内的 ComfyUI（前台日志后台进程）
set -euo pipefail
NAME=comfyui
REPO="${REPO:-$HOME/Repo/comfyui}"

distrobox enter "$NAME" -- bash -lc "
  source '$REPO/ComfyUI/.venv/bin/activate'
  cd '$REPO/ComfyUI'
  nohup python main.py --listen 127.0.0.1 --port 8188 --preview-method auto \
    > '$REPO/comfyui.log' 2>&1 &
  echo \"ComfyUI 已启动: http://127.0.0.1:8188 (日志: $REPO/comfyui.log)\"
"
