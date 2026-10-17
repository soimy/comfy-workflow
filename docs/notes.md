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
11. **工作流有两套格式，侧边栏预置必须是「节点图」格式**：
    从侧边栏点开工作流走 `workflowService.openWorkflow → app.loadGraphData(...)`，
    这条路上**没有** `isApiJson()` 判定（只在拖拽 JSON/读 PNG 元数据那条路上有），
    会直接当节点图解析并访问 `graphData.nodes`；API 格式（顶层 `{"1":{"class_type":...}}`）
    没有 `nodes` 字段，前端就抛 `TypeError: e is not iterable`。
    结论：`workflows/*_api.json` 只给 HTTP `/prompt` 用，画布/预置要另存一份节点图格式。
12. **API 格式顶层不能加 `_comment` 之类字段**：`isApiJson()` 的规则是
    「所有顶层值都必须是带 `class_type` 的对象」（`app.ts` 里还要求 `inputs` 是普通对象），
    多一个数组字段就会判定失败、退化成按节点图解析然后报错。
13. **「widget 被转成输入」的序列化写法**（照着官方模板 `audio_ace_step1_5_xl_base.json` 里
    KSampler 的 seed 抄的）：该入参出现在 `node.inputs` 里并带 `"widget": {"name": "seed"}`，
    同时在 `widgets_values` 里**仍占一个位置**（放默认值即可，实际取链接值）。
    另外 `KSampler` 的 seed 后面前端会多注入一个 `control_after_generate` widget，
    `LoadImage` 的图片上传按钮也算一个 widget（值 `"image"`）。

14. **子图（subgraph）工作流的 JSON 约定**（对照 `utility_seedvr2_3b_int8_upscale_image.json`，
    并用 624 份官方模板统计验证）：
    - 顶层多一个 `definitions.subgraphs` 数组；外层用节点图的那个节点 `type` 直接填子图 `id`（UUID）。
    - 子图内有虚拟代理节点 `inputNode: {"id": -10}` / `outputNode: {"id": -20}`，它们**不出现在 `nodes` 里**，
      但会出现在 `links` 表里：`origin_id = -10` 表示「从子图输入来」，`target_id = -20` 表示「接到子图输出」。
    - 子图 `inputs[].linkIds` 中，每条 link 的 `origin_slot` 等于该输入在 `inputs` 数组里的**下标**；
      `outputs[].linkIds` 里 `origin_slot` 用 `-20` 侧的输出槽位。
    - **只有带 `label` 的子图输入才会同时出现在外层节点的 `inputs` 里**。官方那份 10 个输入里
      仅 `resize_type.multiplier` 带 `label`，外层节点 inputs 里也就只有它 —— 想暴露成端口就得加 `label`。
    - 被提升成控件的入参必须三处同时到位且**顺序一致**：子图输入加 `label`、内部节点入参加
      `{"widget": {"name": ...}}`、外层节点 `properties.proxyWidgets` 记 `[内部节点id, 控件名]`。
    - `widgets_values` 里**仍要保留被提升控件的占位值**（如 KSampler 的 seed/denoise），原理同第 13 条。
    - 子图展开是浏览器侧行为，headless 测不到；结构可机械校验（连线双向登记、槽位索引、类型兼容、
      节点类型存在于 `/object_info`、子图键集合与官方模板比对），但**首次用前必须在界面跑一次**。

15. **自定义节点不要写进 `ComfyUI` submodule 里**（踩过的坑）：
    把 `custom_nodes/ComfyUI-SimpleUpscale/` 放进 submodule 内部会产生**只存在于本地的提交**，
    submodule 指针随之指向官方仓库里不存在的 commit，于是 `git clone --recurse-submodules` 直接失败：
    `upload-pack: not our ref <sha>` / `没有包含 <sha>，直接获取该提交失败`。
    而且换机器时这部分代码永远拿不回来。
    正确做法：自定义节点放**主仓库**的 `custom_nodes/`，安装脚本用软链接挂进 ComfyUI：
    `ln -s "$REPO/custom_nodes/$name" "$COMFY/custom_nodes/$name"`（用软链不用拷贝，改一处两边同步）。
    submodule 指针始终保持在官方上游提交上。
    另注：submodule 内 `__pycache__` 属主是容器内的 uid，宿主机删不掉，需 `podman exec <容器> rm -rf`。

16. **OOM 之后显存可能再也还不回来**，此时「卸载模型」和 `POST /free` 都无效：
    - 症状：`/system_stats` 里 `torch_vram_total` 远大于 `torch_vram_free`（例如 7.44 GiB / 0.01 GiB），
      说明 torch 认为这些张量仍是 active，池里没有可回收的块，`empty_cache` 无块可吐。
    - 判断调用确实执行了（而非没触发）：看 `main.py` 主循环是否被 `set_flag` 唤醒 ——
      调 `/free` 前后对比 `/proc/<pid>/stat` 的 `utime+stime` 增量；以及日志里
      `CacheSet.__init__` 打的 `Using RAM pressure cache.` 就是 `PromptExecutor.reset()` 的指纹。
    - 根治手段只有重启。**注意别用 `podman restart <容器>`**：若 ComfyUI 是 `distrobox enter` /
      `podman exec` 里手敲起来的（不是容器主进程），重启容器只会杀掉它、不会自动拉起。
    - 推荐 `POST /manager/reboot`（等价于 Manager 界面的 Restart）：环境里没有 `__COMFY_CLI_SESSION__`
      时走 `os.execv` **原地重启**，PID 不变、参数不变、日志继续写同一文件，约 10 秒恢复。
    - 实测：SeedVR2 3B int8 在 16 GB 卡上 2x 成功、4x 必 OOM（像素差 4 倍，token 数 204k → 817k，
      单个 bf16 激活 1.0 → 3.9 GiB，单层 fp32 累加缓冲 1.9 → 7.8 GiB）。
      解决办法是分片（空间切块 + 正弦羽化拼接），不是调低精度。
