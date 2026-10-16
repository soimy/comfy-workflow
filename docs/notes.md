# 部署踩坑记录（Bazzite + distrobox + RTX 5080）

1. **RTX 5080 是 Blackwell (sm_120)**：PyTorch 必须使用 cu128 及以上 wheel
   （`pip install torch --index-url https://download.pytorch.org/whl/cu128`），
   cu121/cu124 会报 `CUDA error: no kernel image for sm_120`。
2. **沙盒环境里 nvidia-smi 不可用**是正常的（宿主会话沙盒看不到 /dev/nvidia*），
   以容器内 `podman exec comfyui nvidia-smi` 的结果为准。
3. **distrobox 首次 enter 可能长时间卡在 "Setting up host's nvidia integration"**：
   该步骤在容器内安装 NVIDIA 用户态库。若卡死，改用
   `podman exec comfyui <命令>` 直连操作，不影响使用。
4. Bazzite 是不可变系统，所有运行时依赖装进容器，宿主机保持干净。
5. **HuggingFace Xet 传输在国内网络会报 `CAS Client Error` 且速率极低**：
   下载脚本已设 `HF_HUB_DISABLE_XET=1`，并自动探测 `HF_ENDPOINT`
   （直连可用用官方，否则回退 `https://hf-mirror.com`），实测镜像 ~10MB/s。

