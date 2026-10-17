# ComfyUI + SeedVR2 / SUPIR / Flux Tile 图片放大工作流（distrobox 部署）

宿主机：Bazzite（Fedora Atomic，不可变系统）· podman + distrobox · GPU：RTX 5080（Blackwell / sm_120）

## 部署步骤

```bash
# 1. 创建 distrobox 容器（Ubuntu 24.04 + NVIDIA 透传）
bash scripts/01-create-container.sh

# 2. 容器内安装 ComfyUI / PyTorch cu128 / 自定义节点
distrobox enter comfyui -- bash /var/home/sym/Repo/comfyui/scripts/02-install.sh

# 3. 下载模型（约 34GB，可分步：seedvr2 / supir / flux / all）
distrobox enter comfyui -- bash /var/home/sym/Repo/comfyui/scripts/03-download-models.sh all

# 4. 启动
bash scripts/04-launch.sh   # http://127.0.0.1:8188
```

## 三套放大流程

| 流程 | 核心节点 | 模型 |
|---|---|---|
| SeedVR2 分片 8K | 原生 SeedVR2 + SplitImageToTileList / ImageMergeTileList 空间分片 | seedvr2_3b_int8_convrot + seedvr2_ema_vae_fp16 |
| SUPIR | SUPIR_first_stage → SUPIR_second_stage（SDXL 管线） | SUPIR-v0q + sd_xl_base_1.0 + 4x-UltraSharp |
| Flux Tile | Flux fp8 + TiledDiffusion / UltimateSDUpscale 分块采样 | flux1-dev-fp8 + t5xxl fp8 + clip_l + ae |

- SeedVR2 分片 8K：**长边 8K 首选**。一步式扩散修复（steps=1/cfg=1），无需提示词。
- SUPIR：低清图先经 SUPIR encoder 提升与重述 caption，再用 SDXL 二阶段扩散精修，适合老照片/严重退化图。
- Flux Tile：将大图切块，逐块用 Flux dev 采样（tiled 注意力避免 OOM），适合 2K→4K/8K 高保真放大。

## SeedVR2 分片放大（长边 8K）

`workflows/seedvr2_tile_upscale_api.json`（HTTP/脚本）· `workflows/seedvr2_tile_upscale_ui.json`（画布）

```
LoadImage → 长边缩放到 8192(lanczos) → 切 1536×1536 分片(重叠 128)
  → 逐片: SeedVR2Preprocess → VAEEncodeTiled → SeedVR2Conditioning
          → KSampler(1步) → VAEDecodeTiled → SeedVR2PostProcessing
  → ImageMergeTileList 正弦羽化拼回 → SaveImage
```

SeedVR2 是 **1:1 修复**模型（VAE 空间下采样 8 倍，进出一致），放大倍率来自前面的 lanczos 预缩放，
所以「长边 8K」= 先把长边插值到 8192 再让 SeedVR2 在该分辨率上重建细节。

**为什么必须分片**：采样显存随画面积线性增长（实测系数 ≈0.55 GiB/百万像素 + 约 8.5 GiB 固定开销）。
单张 8192×8192（67MP）整图采样需 >20GB 显存，16GB 卡必 OOM；分片后每片只有 1536²（2.4MP）。

实测（RTX 5080 16GB）：8192×8192 用时 **106 秒**，峰值显存 **14.8GB / 16GB**；4 片小网格 22 秒。

### 尺寸自适应（不用改参数）

`GetImageSize` 把缩放后的真实宽高接到 `ImageMergeTileList` 的 `final_width` / `final_height`，
所以任意长宽比都能直接跑：长边固定 8192，短边按原图比例自动算（尖括号里的两个参数也可手改）。

> 备忘：`ImageMergeTileList` 是 `is_input_list=True` 节点，它内部取 `final_width[0]`，
> 拿到的必须是 list —— 链式输入经 `build_nested_inputs` 包装后满足这一点（已实测 1273×1236 → 8192×7954）。
> 若把这两个参数填成静态数字，则必须与缩放后的真实尺寸**完全一致**，否则会静默出现黑边或裁切。

### 调参

- 想改输出长边：`ImageScaleToMaxDimension.largest_size`（4096 / 8192 / 12288）。
- `SplitImageToTileList.tile_width/height`：显存不够就降到 1280 / 1024（保持 16 的倍数，
  SeedVR2 会把输入 pad 到 16）。分片越小显存越低，但片数变多、边缘接缝风险变大。
- `overlap`：切分与拼合两处必须一致，128 起步；接缝明显可加到 192。
- `SeedVR2PostProcessing.color_correction_method`：默认 `none`（与官方模板一致）。
  若分片之间有轻微色调差，改成 `lab`（更忠实，但逐片各做一次色彩迁移，显存和耗时略增）。
- 想换 7B 模型：`UNETLoader` 改成 `seedvr2_7b_int8_convrot.safetensors`（7.76GB，质量更好、更吃显存）。

## SeedVR2 分片放大 v2（尺寸自适应 + 子图封装）

`workflows/seedvr2_tile_upscale_v2.json`（画布）· 面板预置名 **「App - SeedVR2 8K 分片放大 v2」**

相比 v1 的两处改动：

1. **两个参数，自动取小**——`目标最长边(上限)` 与 `缩放倍率` 二选一生效，实际取算出来较小的那个：

```
LoadImage ─┬─> GetImageSize ─宽/高─┐
           │                      ├─> ComfyMathExpression ─INT─> ImageScaleToMaxDimension.largest_size
           └──────────────────────┘         ↑        ↑
                                    缩放倍率        目标最长边(上限)
                                  PrimitiveFloat    PrimitiveInt
```

表达式 `min(d, round(max(a, b) * c))`（a/b=原图宽高，c=倍率，d=上限），
用自带 `ComfyMathExpression`（底层 `simpleeval`，`min/max/round` 都在白名单）。

| 原图 | 倍率 | 上限 | 实际长边 |
|---|---|---|---|
| 2102×1554 | 4.0 | 8192 | **8192**（4× 会到 8408，被上限截住） |
| 2102×1554 | 2.0 | 8192 | **4204** |
| 1000×800 | 4.0 | 8192 | **4000**（小图吃满倍率，不被硬拉到 8192） |
| 2102×1554 | 4.0 | 4096 | **4096** |

> v1 的坑：`largest_size` 写死 8192，小图会被 lanczos 硬放大到 8192 再分片，白跑分片且糊。

2. **中间节点封装成子图**「SeedVR2 3B Int8 分片放大」，对照官方 `utility_seedvr2_3b_int8_upscale_image` 的粒度：
   装进去的是 UNETLoader / VAELoader / SeedVR2Preprocess / VAEEncodeTiled / SeedVR2Conditioning /
   KSampler / VAEDecodeTiled / SeedVR2PostProcessing；提升到外层面板的控件是
   `unet_name`·`vae_name`·`seed`·`sampler_name`·`scheduler`·`denoise`·`color_correction_method`。

   **缩放/切分/合并留在子图外**——必须先放大再切分，反过来（切完各放 4 倍）单块就爆了。

### 子图 JSON 的几条隐含约定

改子图相关文件时注意（都是从 624 份官方模板反推、再用校验脚本确认的）：

- 子图输入的 `linkIds` 里，`link.origin_id` 是 `-10`（输入代理）、`origin_slot` 等于该输入在
  `subgraphs[].inputs` 数组里的**下标**；输出端对称，`origin_slot` 用 `-20`。
- **只有带 `label` 的子图输入才会同时出现在外层节点的 `inputs` 里**（官方那份 10 个输入里
  仅 `resize_type.multiplier` 带 label，外层节点 inputs 里也就只有它）。
- 被提升成控件的入参要同时：子图输入加 `label`、内部节点入参加
  `{"widget": {"name": ...}}`、外层节点 `properties.proxyWidgets` 记 `[内部节点id, 控件名]`；
  三者顺序必须一致。
- `widgets_values` 里**仍要保留被提升控件的占位值**（如 KSampler 的 seed/denoise）。
- 校验脚本思路：连线双向登记（节点 `outputs[].links` 与链接表互查）、槽位索引一致、
  类型兼容、节点类型存在于 `/object_info`、子图键集合与官方模板逐键比对。

> 子图展开是浏览器侧行为，headless 测不到；结构可机械验证，**首次用前请在界面里跑一次**。

## 两种工作流格式（踩坑重点）

仓库里每套流程都有两份文件，**用途不同、不能混用**：

| 文件 | 格式 | 用在哪 |
|---|---|---|
| `workflows/seedvr2_tile_upscale_api.json` | API（顶层是 `{"1": {"class_type": ...}}`） | 脚本 / HTTP `/prompt` |
| `workflows/seedvr2_tile_upscale_ui.json` | 节点图（顶层是 `nodes` / `links`） | 画布导入、侧边栏预置 |

**侧边栏预置必须是节点图格式**。从侧边栏点开工作流走的是
`workflowService.openWorkflow → app.loadGraphData(...)`，这条路上**没有** `isApiJson()` 判定
（那个判定只在拖拽文件/读 PNG 元数据那条路上），它会直接当节点图解析并访问 `graphData.nodes`。
API 格式没有 `nodes` 字段，于是前端抛 `TypeError: e is not iterable`。
另外 API 格式顶层**不要加 `_comment` 之类的字段**，`isApiJson()` 的规则是
「所有顶层值都必须是带 `class_type` 的对象」，多一个数组字段就会退化成按节点图解析然后报错。

## 面板预置工作流

ComfyUI 侧边栏读的是 `ComfyUI/user/default/workflows/`，该目录在 submodule 里被 gitignore，
所以预置文件不入库，换机器/重装要再放一次（复制过去即出现在面板里，无需重启）：

```bash
cp workflows/seedvr2_tile_upscale_ui.json "ComfyUI/user/default/workflows/App - SeedVR2 8K 分片放大.json"
cp workflows/seedvr2_tile_upscale_v2.json "ComfyUI/user/default/workflows/App - SeedVR2 8K 分片放大 v2.json"
cp workflows/flux_tile_upscale_api.json  "ComfyUI/user/default/workflows/App - Flux Tile 放大.json"
cp workflows/supir_upscale_api.json      "ComfyUI/user/default/workflows/App - SUPIR 放大.json"
```

> 后两份用的是 `SimpleUpscale` 单节点 App（本身是节点图，直接复制即可）。
> SeedVR2 这份由 `seedvr2_tile_upscale_api.json` 生成，生成脚本会：
> 用 `/object_info` 判定每个入参是 widget 还是连线、把「被转成输入的 widget」
> 序列化成 `{"name": ..., "widget": {"name": ...}, "link": ...}` 并保留占位值、
> 计算拓扑 `order` 与布局；转换后再反向还原成 API 格式与原文件逐字段比对，确保语义一致。

## 目录

```
scripts/   01 容器 → 02 安装 → 03 模型 → 04 启动
workflows/ *_api.json = HTTP/脚本用；*_ui.json = 画布/面板预置用
ComfyUI/   运行时目录（大文件不入库）
```
