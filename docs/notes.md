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
6. **SeedVR2 已是 ComfyUI 0.41 的原生能力，不要装第三方 SeedVR2 节点包**：
   模型用普通 `UNETLoader` 直接加载（`seedvr2_3b_int8_convrot.safetensors`，
   int8 量化，日志会打印 `Detected mixed precision quantization`），配套原生节点为
   `SeedVR2Preprocess / SeedVR2Conditioning / SeedVR2PostProcessing / SeedVR2TemporalChunk /
   SeedVR2TemporalMerge`。官方图片模板在 `comfyui_workflow_templates_json` 包里
   （`utility_seedvr2_3b_int8_upscale_image.json`），视频模板另有
   `blueprints/Upscale Video (SeedVR2 3B Int8).json`。
7. **SeedVR2 是 1:1 修复模型，本身没有放大倍率**：VAE `spatial_downsample_factor = 8`，
   `decode_output_shape` 输出 = 输入尺寸。放大倍率全部来自前置 lanczos 缩放
   （官方模板用 `scale by multiplier 4`）。所以「放大到 8K」= 先把长边插值到 8192 再让模型重建细节。
8. **`ImageMergeTileList` 的 `final_width/final_height` 可以接链式输入**（最初看代码以为不行，
   实测可行）：节点内部取 `final_width[0]`，V3 节点经 `build_nested_inputs` 会把链式输入包成 list，
   所以 `GetImageSize` 的 width/height 直接接进去就能自动适配任意长宽比（实测 1273×1236 → 8192×7954）。
   但如果写成静态 widget，就必须和缩放后的真实尺寸完全一致，否则**不报错**、直接黑边或裁切。
9. **分片尺寸取 16 的倍数**：`SeedVR2Preprocess` 会把图 pad 到 16 的倍数，
   `SeedVR2PostProcessing` 再把宽高裁到偶数。用 1536 这类尺寸可以保证拼图时每片尺寸一致。
10. **ComfyUI 的模型列表按目录 mtime 自动失效**：新下载的模型不用重启服务，
    `/object_info/UNETLoader` 立刻就能看到。

