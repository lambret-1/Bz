"""
RealESRGAN_x2 → Core ML 模型转换脚本

功能：
    1. 从 HuggingFace 下载 RealESRGAN_x2.pth 权重
    2. 加载 RRDBNet 模型并载入权重
    3. 转换为 Core ML mlprogram 格式（FP16，512×512 输入）
    4. 输出 real_esrgan_x2.mlpackage

使用方式：
    python convert_esrgan_x2.py
"""

import os
import sys
import urllib.request
import torch
import torch.nn as nn
import coremltools as ct
import numpy as np

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))

# ==================== 配置 ====================
MODEL_PTH_URL = "https://huggingface.co/ai-forever/Real-ESRGAN/resolve/main/RealESRGAN_x2.pth"
INPUT_WIDTH = 512
INPUT_HEIGHT = 512
OUTPUT_PACKAGE = os.path.join(SCRIPT_DIR, "real_esrgan_x2.mlpackage")


# ==================== RRDBNet 定义 ====================
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
        self.rrdb_trunk = nn.Sequential(*[RRDB(nf, gc) for _ in range(nb)])
        self.conv_trunk = nn.Conv2d(nf, nf, 3, 1, 1)

        if scale == 2:
            self.upconv1 = nn.Conv2d(nf, nf * 4, 3, 1, 1)
            self.pixel_shuffle = nn.PixelShuffle(2)
        elif scale == 4:
            self.upconv1 = nn.Conv2d(nf, nf * 4, 3, 1, 1)
            self.upconv2 = nn.Conv2d(nf, nf * 4, 3, 1, 1)
            self.pixel_shuffle = nn.PixelShuffle(2)

        self.conv_hr = nn.Conv2d(nf, nf, 3, 1, 1)
        self.conv_last = nn.Conv2d(nf, out_nc, 3, 1, 1)
        self.lrelu = nn.LeakyReLU(negative_slope=0.2, inplace=True)

    def forward(self, x):
        feat = self.conv_first(x)
        trunk = self.conv_trunk(self.rrdb_trunk(feat))
        feat = feat + trunk

        if self.scale == 2:
            feat = self.lrelu(self.pixel_shuffle(self.upconv1(feat)))
        elif self.scale == 4:
            feat = self.lrelu(self.pixel_shuffle(self.upconv1(feat)))
            feat = self.lrelu(self.pixel_shuffle(self.upconv2(feat)))

        out = self.conv_last(self.lrelu(self.conv_hr(feat)))
        return out


# ==================== 下载权重 ====================
def download_model_weights() -> str:
    pth_path = os.path.join(SCRIPT_DIR, "RealESRGAN_x2.pth")
    if os.path.exists(pth_path):
        print(f"📦 已存在: {pth_path}")
        return pth_path
    print("⬇️  下载 RealESRGAN_x2.pth ...")
    urllib.request.urlretrieve(MODEL_PTH_URL, pth_path)
    print(f"✅ 大小: {os.path.getsize(pth_path) / 1024 / 1024:.1f} MB")
    return pth_path


# ==================== 加载模型 ====================
def load_model(pth_path: str) -> RRDBNet:
    print("🔧 加载模型...")
    model = RRDBNet(in_nc=3, out_nc=3, nf=64, nb=23, gc=32, scale=2)
    checkpoint = torch.load(pth_path, map_location='cpu', weights_only=False)
    if 'params' in checkpoint:
        state_dict = checkpoint['params']
    else:
        state_dict = checkpoint
    model.load_state_dict(state_dict, strict=True)
    model.eval()
    param_count = sum(p.numel() for p in model.parameters())
    print(f"✅ 参数量: {param_count / 1e6:.1f}M")
    return model


# ==================== 转换 ====================
def convert_to_coreml(model: RRDBNet) -> ct.models.MLModel:
    print(f"🔄 转换为 Core ML ({INPUT_WIDTH}x{INPUT_HEIGHT})...")
    example_input = torch.rand(1, 3, INPUT_HEIGHT, INPUT_WIDTH)
    traced = torch.jit.trace(model, example_input)
    mlmodel = ct.convert(
        traced,
        convert_to="mlprogram",
        inputs=[ct.ImageType(
            name="input",
            shape=(1, 3, INPUT_HEIGHT, INPUT_WIDTH),
            scale=1/255.0,
            bias=[0, 0, 0]
        )],
        outputs=[ct.ImageType(name="output")],
        compute_precision=ct.precision.FLOAT16,
        minimum_deployment_target=ct.target.iOS16
    )
    mlmodel.short_description = "RealESRGAN x2 超分模型（512x512 瓦片）"
    print("✅ 转换完成")
    return mlmodel


def main():
    print("=" * 60)
    print("RealESRGAN_x2 → Core ML")
    print("=" * 60)
    pth_path = download_model_weights()
    model = load_model(pth_path)
    mlmodel = convert_to_coreml(model)
    print(f"💾 保存到: {OUTPUT_PACKAGE}")
    mlmodel.save(OUTPUT_PACKAGE)
    total = sum(os.path.getsize(os.path.join(r, f)) for r, _, fs in os.walk(OUTPUT_PACKAGE) for f in fs)
    print(f"✅ 大小: {total / 1024 / 1024:.1f} MB")


if __name__ == "__main__":
    main()
