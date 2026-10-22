"""
RealESRGAN_x2plus → Core ML 模型转换脚本（官方标准版）
"""

import os
import copy
import argparse
import urllib.request
import torch
import torch.nn as nn
import torch.nn.functional as F
import coremltools as ct
import numpy as np

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))

# ==================== 配置 ====================
# 官方 x2plus 权重地址（GitHub Release）
MODEL_PTH_URL = "https://github.com/xinntao/Real-ESRGAN/releases/download/v0.2.1/RealESRGAN_x2plus.pth"
INPUT_WIDTH = 512
INPUT_HEIGHT = 512
OUTPUT_PACKAGE = os.path.join(SCRIPT_DIR, "real_esrgan_x2_official.mlpackage")
SCALE = 2

# ==================== 官方模型定义 ====================
class ResidualDenseBlock(nn.Module):
    def __init__(self, nf=64, gc=32):
        super().__init__()
        self.conv1 = nn.Conv2d(nf, gc, 3, 1, 1)
        self.conv2 = nn.Conv2d(nf + gc, gc, 3, 1, 1)
        self.conv3 = nn.Conv2d(nf + 2 * gc, gc, 3, 1, 1)
        self.conv4 = nn.Conv2d(nf + 3 * gc, gc, 3, 1, 1)
        self.conv5 = nn.Conv2d(nf + 4 * gc, nf, 3, 1, 1)
        self.lrelu = nn.LeakyReLU(negative_slope=0.2, inplace=True)

    def forward(self, x):
        x1 = self.lrelu(self.conv1(x))
        x2 = self.lrelu(self.conv2(torch.cat((x, x1), 1)))
        x3 = self.lrelu(self.conv3(torch.cat((x, x1, x2), 1)))
        x4 = self.lrelu(self.conv4(torch.cat((x, x1, x2, x3), 1)))
        x5 = self.conv5(torch.cat((x, x1, x2, x3, x4), 1))
        return x5 * 0.2 + x

class RRDB(nn.Module):
    def __init__(self, nf=64, gc=32):
        super().__init__()
        self.rdb1 = ResidualDenseBlock(nf, gc)
        self.rdb2 = ResidualDenseBlock(nf, gc)
        self.rdb3 = ResidualDenseBlock(nf, gc)

    def forward(self, x):
        out = self.rdb1(x)
        out = self.rdb2(out)
        out = self.rdb3(out)
        return out * 0.2 + x

class RRDBNet(nn.Module):
    def __init__(self, in_nc=3, out_nc=3, nf=64, nb=23, gc=32, scale=2):
        super().__init__()
        self.scale = scale
        self.conv_first = nn.Conv2d(in_nc, nf, 3, 1, 1)
        self.body = nn.Sequential(*[RRDB(nf, gc) for _ in range(nb)])
        self.conv_body = nn.Conv2d(nf, nf, 3, 1, 1)
        
        # 官方结构：conv_up1 始终存在，conv_up2 仅 4x 模型才有
        self.conv_up1 = nn.Conv2d(nf, nf, 3, 1, 1)
        if scale == 4:
            self.conv_up2 = nn.Conv2d(nf, nf, 3, 1, 1)  # 2x 模型不会执行此行
        
        self.conv_hr = nn.Conv2d(nf, nf, 3, 1, 1)
        self.conv_last = nn.Conv2d(nf, out_nc, 3, 1, 1)
        self.lrelu = nn.LeakyReLU(negative_slope=0.2, inplace=True)
        self.upsample = nn.Upsample(scale_factor=2, mode='nearest')

    def forward(self, x):
        feat = self.conv_first(x)
        trunk = self.conv_body(self.body(feat))
        feat = feat + trunk
        
        feat = self.lrelu(self.conv_up1(self.upsample(feat)))
        if self.scale == 4:  # 2x 模型不会执行此行
            feat = self.lrelu(self.conv_up2(self.upsample(feat)))
        
        out = self.conv_last(self.lrelu(self.conv_hr(feat)))
        return out

# ==================== 可选的 PixelShuffle 优化 ====================
def upsample_conv_to_pixelshuffle(conv: nn.Conv2d, r: int = 2) -> nn.Conv2d:
    """将 Upsample+Conv 等价转换为 Conv+PixelShuffle，用于提升 ANE 性能"""
    C_out, C_in, k, _ = conv.weight.shape
    assert k == 3
    pad = 1
    new_conv = nn.Conv2d(C_in, C_out * r * r, k, 1, pad, bias=conv.bias is not None)
    with torch.no_grad():
        new_w = torch.zeros(C_out * r * r, C_in, k, k)
        new_b = torch.zeros(C_out * r * r) if conv.bias is not None else None
        for p in range(r):
            for q in range(r):
                sub = p * r + q
                W_sub = torch.zeros(C_out, C_in, k, k)
                for di in range(-pad, pad + 1):
                    for dj in range(-pad, pad + 1):
                        di_p = (p + di) // r
                        dj_q = (q + dj) // r
                        W_sub[:, :, di_p + pad, dj_q + pad] += conv.weight[:, :, di + pad, dj + pad]
                new_w[sub * C_out:(sub + 1) * C_out] = W_sub
                if new_b is not None:
                    new_b[sub * C_out:(sub + 1) * C_out] = conv.bias
        new_conv.weight.copy_(new_w)
        if new_b is not None:
            new_conv.bias.copy_(new_b)
    return new_conv

def apply_pixelshuffle(model: RRDBNet) -> RRDBNet:
    old_up1 = model.conv_up1
    old_up2 = getattr(model, 'conv_up2', None)
    model.conv_up1 = upsample_conv_to_pixelshuffle(old_up1, r=2)
    if old_up2 is not None:
        model.conv_up2 = upsample_conv_to_pixelshuffle(old_up2, r=2)
    scale = model.scale

    def new_forward(self, x):
        feat = self.conv_first(x)
        trunk = self.conv_body(self.body(feat))
        feat = feat + trunk
        feat = self.conv_up1(feat)
        feat = F.pixel_shuffle(feat, 2)
        feat = self.lrelu(feat)
        if scale == 4:
            feat = self.conv_up2(feat)
            feat = F.pixel_shuffle(feat, 2)
            feat = self.lrelu(feat)
        out = self.conv_last(self.lrelu(self.conv_hr(feat)))
        return out

    model.forward = new_forward.__get__(model, RRDBNet)
    print("  ✅ Upsample+Conv -> Conv+PixelShuffle 替换完成")
    return model

# ==================== 下载 / 加载 ====================
def download_model_weights() -> str:
    pth_path = os.path.join(SCRIPT_DIR, "RealESRGAN_x2plus.pth")
    if os.path.exists(pth_path):
        print(f"📦 已存在: {pth_path}")
        return pth_path
    print("⬇️  下载 RealESRGAN_x2plus.pth ...")
    urllib.request.urlretrieve(MODEL_PTH_URL, pth_path)
    print(f"✅ 大小: {os.path.getsize(pth_path) / 1024 / 1024:.1f} MB")
    return pth_path

def load_model_official(pth_path: str) -> RRDBNet:
    print("🔧 加载官方 3 通道模型 (x2plus)...")
    model = RRDBNet(in_nc=3, out_nc=3, nf=64, nb=23, gc=32, scale=SCALE)
    checkpoint = torch.load(pth_path, map_location='cpu', weights_only=False)
    state_dict = checkpoint.get('params', checkpoint)
    
    # 严格加载，结构必须与官方完全一致
    model.load_state_dict(state_dict, strict=True)
    model.eval()
    param_count = sum(p.numel() for p in model.parameters())
    print(f"✅ 参数量: {param_count / 1e6:.1f}M")
    return model

# ==================== 转换 ====================
def convert_to_coreml(model: RRDBNet, in_channels: int) -> ct.models.MLModel:
    print(f"🔄 转换为 Core ML ({INPUT_WIDTH}x{INPUT_HEIGHT}, in={in_channels}ch)...")
    example_input = torch.rand(1, in_channels, INPUT_HEIGHT, INPUT_WIDTH)
    traced = torch.jit.trace(model, example_input, strict=False)
    mlmodel = ct.convert(
        traced,
        convert_to="mlprogram",
        inputs=[ct.TensorType(name="input", shape=(1, in_channels, INPUT_HEIGHT, INPUT_WIDTH), dtype=np.float32)],
        outputs=[ct.TensorType(name="output")],
        compute_precision=ct.precision.FLOAT16,
        minimum_deployment_target=ct.target.iOS16
    )
    mlmodel.short_description = f"RealESRGAN {SCALE}x 官方模型（{INPUT_WIDTH}x{INPUT_HEIGHT} 瓦片，{in_channels}ch 输入）"
    print("✅ 转换完成")
    return mlmodel

# ==================== 主流程 ====================
def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--pixel-shuffle", action="store_true", help="启用 PixelShuffle 改写（默认关闭，保持官方原始结构）")
    args = parser.parse_args()

    print("=" * 60)
    print("RealESRGAN_x2plus → Core ML（官方标准版）")
    print(f"  PixelShuffle 改写: {'启用' if args.pixel_shuffle else '关闭 (官方原始结构)'}")
    print("=" * 60)

    pth_path = download_model_weights()
    model = load_model_official(pth_path)

    if args.pixel_shuffle:
        print("\n[1/3] PixelShuffle 改写")
        model_ps = copy.deepcopy(model)
        model_ps = apply_pixelshuffle(model_ps)
        model_ps.eval()
        final_model = model_ps
    else:
        print("\n[1/3] 保持官方原始结构 (Upsample + Conv)")
        final_model = model

    print("\n[2/3] Core ML 转换")
    mlmodel = convert_to_coreml(final_model, in_channels=3)

    print(f"\n[3/3] 保存到: {OUTPUT_PACKAGE}")
    mlmodel.save(OUTPUT_PACKAGE)
    total = sum(os.path.getsize(os.path.join(r, f)) for r, _, fs in os.walk(OUTPUT_PACKAGE) for f in fs)
    print(f"✅ 完成，大小: {total / 1024 / 1024:.1f} MB")

if __name__ == "__main__":
    main()