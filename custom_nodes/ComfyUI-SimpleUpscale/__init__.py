"""SimpleUpscale: 一键式图片放大 App 节点。

只暴露「上传图片 + 缩放倍数」，内部封装完整管线：
- SimpleSUPIRUpscale:    SUPIR (SDXL 管线)
- SimpleFluxTileUpscale: Flux dev fp8 + TiledDiffusion 分块重采样
"""
import importlib

import comfy.utils
import comfy.sample
import comfy.samplers
import node_helpers
import folder_paths


def _pre_scale(image, scale):
    """按倍数 lanczos 预放大输入图 (Comfy [B,H,W,C])"""
    if abs(scale - 1.0) < 1e-3:
        return image
    h, w = image.shape[1:3]
    img = comfy.utils.lanczos(image.movedim(-1, 1), round(w * scale), round(h * scale))
    return img.movedim(1, -1).clamp(0, 1)


def _nodes():
    return importlib.import_module("nodes")


_supir = {"loader": None}
_flux = {}


class SimpleSUPIRUpscale:
    @classmethod
    def INPUT_TYPES(s):
        return {
            "required": {
                "image": ("IMAGE",),
                "scale": ("FLOAT", {"default": 2.0, "min": 1.0, "max": 4.0, "step": 0.25}),
                "positive_prompt": ("STRING", {"multiline": True, "default": "high quality, detailed, sharp focus, photorealistic"}),
                "negative_prompt": ("STRING", {"multiline": True, "default": "painting, illustration, low quality, lowres, watermark, blurry"}),
                "seed": ("INT", {"default": 42, "min": 0, "max": 0xFFFFFFFFFFFFFFFF}),
                "steps": ("INT", {"default": 50, "min": 10, "max": 100}),
            }
        }

    RETURN_TYPES = ("IMAGE",)
    FUNCTION = "run"
    CATEGORY = "SimpleUpscale"

    def run(self, image, scale, positive_prompt, negative_prompt, seed, steps):
        m = importlib.import_module("custom_nodes.ComfyUI-SUPIR.nodes_v2")
        core = _nodes()
        img = _pre_scale(image, scale)

        if _supir["loader"] is None:
            _supir["loader"] = m.SUPIR_model_loader_v2()
        model, clip, vae = core.CheckpointLoaderSimple().load_checkpoint(
            "sd_xl_base_1.0_0.9vae.safetensors")
        supir_model, supir_vae = _supir["loader"].process(
            "SUPIR-v0Q_fp16.safetensors", "auto", False, model, clip, vae)

        _, _, latents = m.SUPIR_first_stage().process(supir_vae, img, "auto", True, 1024, 768)
        pos, neg = m.SUPIR_conditioner().condition(supir_model, latents, positive_prompt, negative_prompt)
        out_latents = m.SUPIR_sample().sample(
            supir_model, latents, steps, seed, 4.0, 5, 1.003, pos, neg,
            4.0, 0.7, 0.8, 4.0, True, 1.0, "TiledRestoreEDMSampler", 1024, 128)[0]
        out = m.SUPIR_decode().decode(supir_vae, out_latents, True, 768, "auto")[0]
        return (out,)


class SimpleFluxTileUpscale:
    @classmethod
    def INPUT_TYPES(s):
        return {
            "required": {
                "image": ("IMAGE",),
                "scale": ("FLOAT", {"default": 2.0, "min": 1.0, "max": 4.0, "step": 0.25}),
                "prompt": ("STRING", {"multiline": True, "default": "sharp focus, highly detailed, high quality photo"}),
                "denoise": ("FLOAT", {"default": 0.35, "min": 0.1, "max": 0.8, "step": 0.05}),
                "seed": ("INT", {"default": 42, "min": 0, "max": 0xFFFFFFFFFFFFFFFF}),
                "steps": ("INT", {"default": 20, "min": 4, "max": 50}),
            }
        }

    RETURN_TYPES = ("IMAGE",)
    FUNCTION = "run"
    CATEGORY = "SimpleUpscale"

    def run(self, image, scale, prompt, denoise, seed, steps):
        if "unet" not in _flux:
            core = importlib.import_module("nodes")
            tiled = importlib.import_module("custom_nodes.ComfyUI-TiledDiffusion.tiled_diffusion")
            unet = core.UNETLoader().load_unet("flux1-dev-fp8.safetensors", "fp8_e4m3fn")[0]
            clip = core.DualCLIPLoader().load_clip(
                "clip_l.safetensors", "t5xxl_fp8_e4m3fn.safetensors", "flux")[0]
            vae = core.VAELoader().load_vae("ae.safetensors")[0]
            _flux.update(unet=unet, clip=clip, vae=vae, core=core, tiled=tiled)

        c = _flux
        img = _pre_scale(image, scale)
        latent = c["core"].VAEEncode().encode(c["vae"], img)[0]
        tiled_model = c["tiled"].TiledDiffusion().apply(
            c["unet"], "MultiDiffusion", 1024, 1024, 64, 1)[0]
        positive = node_helpers.conditioning_set_values(
            c["core"].CLIPTextEncode().encode(c["clip"], prompt)[0], {"guidance": 2.5})
        negative = c["core"].CLIPTextEncode().encode(c["clip"], "")[0]
        samples = c["core"].KSampler().sample(
            tiled_model, seed, steps, 1.0, "euler", "simple",
            positive, negative, latent, denoise)[0]
        return c["core"].VAEDecode().decode(c["vae"], samples)


NODE_CLASS_MAPPINGS = {
    "SimpleSUPIRUpscale": SimpleSUPIRUpscale,
    "SimpleFluxTileUpscale": SimpleFluxTileUpscale,
}
NODE_DISPLAY_NAME_MAPPINGS = {
    "SimpleSUPIRUpscale": "一键放大 (SUPIR)",
    "SimpleFluxTileUpscale": "一键放大 (Flux Tile)",
}
