# ComfyUI + SUPIR / Flux Tile 图片放大工作流（distrobox 部署）

宿主机：Bazzite（Fedora Atomic，不可变系统）· podman + distrobox · GPU：RTX 5080（Blackwell / sm_120）

## 部署步骤

```bash
# 1. 创建 distrobox 容器（Ubuntu 24.04 + NVIDIA 透传）
bash scripts/01-create-container.sh

# 2. 容器内安装 ComfyUI / PyTorch cu128 / 自定义节点
distrobox enter comfyui -- bash /var/home/sym/Repo/comfyui/scripts/02-install.sh

# 3. 下载模型（约 30GB，可分步：supir / flux / all）
distrobox enter comfyui -- bash /var/home/sym/Repo/comfyui/scripts/03-download-models.sh all

# 4. 启动
bash scripts/04-launch.sh   # http://127.0.0.1:8188
```

## 两套放大流程

| 流程 | 核心节点 | 模型 |
|---|---|---|
| SUPIR | SUPIR_first_stage → SUPIR_second_stage（SDXL 管线） | SUPIR-v0q + sd_xl_base_1.0 + 4x-UltraSharp |
| Flux Tile | Flux fp8 + TiledDiffusion / UltimateSDUpscale 分块采样 | flux1-dev-fp8 + t5xxl fp8 + clip_l + ae |

- SUPIR：低清图先经 SUPIR encoder 提升与重述 caption，再用 SDXL 二阶段扩散精修，适合老照片/严重退化图。
- Flux Tile：将大图切块，逐块用 Flux dev 采样（tiled 注意力避免 OOM），适合 2K→4K/8K 高保真放大。

## 目录

```
scripts/   01 容器 → 02 安装 → 03 模型 → 04 启动
workflows/ 工作流 JSON（ComfyUI 中 Load 导入）
ComfyUI/   运行时目录（大文件不入库）
```
