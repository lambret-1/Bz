"""
RealESRGAN_x2 → Core ML 模型转换脚本（P2 版）

P2 改动：
    1. 12 通道 → 3 通道权重迁移（等效权重 = 4 份权重之和，带数值验证）
    2. 可选：Upsample(nearest, 2) + Conv3x3 → Conv3x3 + PixelShuffle(2)（带数值验证）
    3. 修正输入 shape 笔误、outputs 不指定 shape（coremltools 约束）
    4. 每个阶段都做数值等价性验证，验证失败直接中止

使用方式：
    python convert_esrgan_x2_p2.py                # 只做 12→3
    python convert_esrgan_x2_p2.py --pixel-shuffle # 同时做 Upsample→PixelShuffle
"""

import os
import sys
import copy
import types
import argparse
import urllib.request
import torch
import torch.nn as nn
import torch.nn.functional as F
import coremltools as ct
import numpy as np

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))

# ==================== 配置 ====================
MODEL_PTH_URL = "https://huggingface.co/ai-forever/Real-ESRGAN/resolve/main/RealESRGAN_x2.pth"
INPUT_WIDTH = 256
INPUT_HEIGHT = 256
OUTPUT_PACKAGE = os.path.join(SCRIPT_DIR, "real_esrgan_x2.mlpackage")
SCALE = 4


# ==================== 模型定义 ====================
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
    def __init__(self, in_nc=12, out_nc=3, nf=64, nb=23, gc=32, scale=2):
        super().__init__()
        self.scale = scale
        self.conv_first = nn.Conv2d(in_nc, nf, 3, 1, 1)
        self.body = nn.Sequential(*[RRDB(nf, gc) for _ in range(nb)])
        self.conv_body = nn.Conv2d(nf, nf, 3, 1, 1)
        self.conv_up1 = nn.Conv2d(nf, nf, 3, 1, 1)
        if scale == 4:
            self.conv_up2 = nn.Conv2d(nf, nf, 3, 1, 1)
        self.conv_hr = nn.Conv2d(nf, nf, 3, 1, 1)
        self.conv_last = nn.Conv2d(nf, out_nc, 3, 1, 1)
        self.lrelu = nn.LeakyReLU(negative_slope=0.2, inplace=True)
        self.upsample = nn.Upsample(scale_factor=2, mode='nearest')

    def forward(self, x):
        feat = self.conv_first(x)
        trunk = self.conv_body(self.body(feat))
        feat = feat + trunk
        feat = self.lrelu(self.conv_up1(self.upsample(feat)))
        if self.scale == 4:
            feat = self.lrelu(self.conv_up2(self.upsample(feat)))
        out = self.conv_last(self.lrelu(self.conv_hr(feat)))
        return out


# ==================== P2-1: 12 → 3 通道迁移 ====================

def migrate_12ch_to_3ch(model: RRDBNet) -> RRDBNet:
    """
    把 conv_first 从 12 通道改成 3 通道。
    推理时 12 通道 = 4 份相同的 RGB（[R,G,B,R,G,B,R,G,B,R,G,B]），
    卷积对输入通道是线性的，所以等效 3 通道权重 = 4 份权重之和。
    """
    old_conv = model.conv_first
    assert old_conv.in_channels == 12, f"期望 12 通道，实际 {old_conv.in_channels}"

    new_conv = nn.Conv2d(
        3, old_conv.out_channels, old_conv.kernel_size,
        old_conv.stride, old_conv.padding,
        bias=old_conv.bias is not None
    )

    with torch.no_grad():
        w = old_conv.weight  # [64, 12, 3, 3]
        new_w = w[:, 0:3] + w[:, 3:6] + w[:, 6:9] + w[:, 9:12]
        new_conv.weight.copy_(new_w)
        if old_conv.bias is not None:
            new_conv.bias.copy_(old_conv.bias)

    model.conv_first = new_conv
    model.in_nc = 3
    print("  ✅ conv_first: 12ch -> 3ch，权重求和迁移完成")
    return model


def verify_12to3(model_12: RRDBNet, model_3: RRDBNet, device='cpu'):
    """数值验证：12 通道（4 份相同 RGB）与 3 通道模型输出一致"""
    model_12.eval()
    model_3.eval()

    torch.manual_seed(42)
    x3 = torch.rand(1, 3, 64, 64, device=device)   # 小尺寸验证
    x12 = x3.repeat(1, 4, 1, 1)                    # [R,G,B,R,G,B,R,G,B,R,G,B]

    with torch.no_grad():
        y12 = model_12(x12)
        y3 = model_3(x3)

    max_diff = (y12 - y3).abs().max().item()
    rel_diff = max_diff / (y12.abs().max().item() + 1e-8)
    print(f"  🔍 12ch vs 3ch: max_abs_diff={max_diff:.3e}, rel={rel_diff:.3e}")

    if max_diff > 1e-4:
        raise RuntimeError(f"❌ 12→3 迁移不等价，diff={max_diff:.3e}")

    print("  ✅ 12→3 通道迁移数值等价")


# ==================== P2-2: Upsample+Conv → Conv+PixelShuffle ====================

def upsample_conv_to_pixelshuffle(conv: nn.Conv2d, r: int = 2) -> nn.Conv2d:
    """
    把 Upsample(nearest, r) + Conv3x3 等价转换为 Conv3x3 + PixelShuffle(r)。

    数学推导：
        原: y[2i+p, 2j+q] = Σ_{di,dj} W[di,dj] · x_up[2i+p+di, 2j+q+dj]
            其中 x_up[2u+a, 2v+b] = x[u, v]（nearest）
        新: y'[2i+p, 2j+q] = z[p·r+q, i, j]
            z[c, i, j] = Σ_{di',dj'} W_new[c, di', dj'] · x[i+di', j+dj']

        令 di_p = (p+di) // r，dj_q = (q+dj) // r，则：
            W_new[p·r+q, di_p, dj_q] = Σ_{di,dj: (p+di)//r=di_p, (q+dj)//r=dj_q} W[di,dj]

    PyTorch 的 pixel_shuffle 通道排列：input[c], c = p·r + q → output 位置 (p, q)。
    """
    C_out, C_in, k, _ = conv.weight.shape
    assert k == 3, f"只支持 3x3 conv，实际 {k}x{k}"
    pad = k // 2  # 1

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
                        assert -pad <= di_p <= pad and -pad <= dj_q <= pad, \
                            f"越界: p={p}, di={di} -> di_p={di_p}"
                        W_sub[:, :, di_p + pad, dj_q + pad] += conv.weight[:, :, di + pad, dj + pad]

                new_w[sub * C_out:(sub + 1) * C_out] = W_sub
                if new_b is not None:
                    new_b[sub * C_out:(sub + 1) * C_out] = conv.bias

        new_conv.weight.copy_(new_w)
        if new_b is not None:
            new_conv.bias.copy_(new_b)

    return new_conv


def apply_pixelshuffle(model: RRDBNet) -> RRDBNet:
    """替换 conv_up1 / conv_up2，并改写 forward"""
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

        feat = self.conv_up1(feat)          # Conv3x3 (nf -> nf*4)
        feat = F.pixel_shuffle(feat, 2)     # -> [B, nf, 2H, 2W]
        feat = self.lrelu(feat)

        if scale == 4:
            feat = self.conv_up2(feat)
            feat = F.pixel_shuffle(feat, 2)
            feat = self.lrelu(feat)

        out = self.conv_last(self.lrelu(self.conv_hr(feat)))
        return out

    model.forward = types.MethodType(new_forward, model)
    print("  ✅ Upsample+Conv -> Conv+PixelShuffle 替换完成")
    return model


def verify_pixelshuffle(model_old: RRDBNet, model_new: RRDBNet, in_ch: int, device='cpu'):
    """数值验证：原 Upsample 模型与 PixelShuffle 模型输出一致"""
    model_old.eval()
    model_new.eval()

    torch.manual_seed(0)
    x = torch.rand(1, in_ch, 32, 32, device=device)

    with torch.no_grad():
        y_old = model_old(x)
        y_new = model_new(x)

    max_diff = (y_old - y_new).abs().max().item()
    rel_diff = max_diff / (y_old.abs().max().item() + 1e-8)
    print(f"  🔍 Upsample vs PixelShuffle: max_abs_diff={max_diff:.3e}, rel={rel_diff:.3e}")

    if max_diff > 1e-4:
        raise RuntimeError(f"❌ PixelShuffle 改写不等价，diff={max_diff:.3e}")

    print("  ✅ Upsample→PixelShuffle 数值等价")


# ==================== 下载 / 加载 ====================

def download_model_weights() -> str:
    pth_path = os.path.join(SCRIPT_DIR, "RealESRGAN_x2.pth")
    if os.path.exists(pth_path):
        print(f"📦 已存在: {pth_path}")
        return pth_path
    print("⬇️  下载 RealESRGAN_x2.pth ...")
    urllib.request.urlretrieve(MODEL_PTH_URL, pth_path)
    print(f"✅ 大小: {os.path.getsize(pth_path) / 1024 / 1024:.1f} MB")
    return pth_path


def load_model_12ch(pth_path: str) -> RRDBNet:
    print("🔧 加载 12 通道模型...")
    model = RRDBNet(in_nc=12, out_nc=3, nf=64, nb=23, gc=32, scale=SCALE)
    checkpoint = torch.load(pth_path, map_location='cpu', weights_only=False)
    state_dict = checkpoint.get('params', checkpoint)

    first_key = [k for k in state_dict.keys() if k.endswith('conv_first.weight')][0]
    first_shape = state_dict[first_key].shape
    print(f"  📐 conv_first.weight shape: {first_shape}")
    assert first_shape[1] == 12, f"期望 12 通道权重，实际 {first_shape[1]}"

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
        inputs=[ct.TensorType(
            name="input",
            shape=(1, in_channels, INPUT_HEIGHT, INPUT_WIDTH),
            dtype=np.float32
        )],
        # 修复：outputs 不能指定 shape（coremltools 自动推断）
        outputs=[ct.TensorType(name="output")],
        compute_precision=ct.precision.FLOAT16,
        minimum_deployment_target=ct.target.iOS16
    )
    mlmodel.short_description = f"RealESRGAN {SCALE}x 超分模型（{INPUT_WIDTH}x{INPUT_HEIGHT} 瓦片，{in_channels}ch 输入）"
    print("✅ 转换完成")
    return mlmodel


# ==================== 主流程 ====================

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--pixel-shuffle", action="store_true",
                        help="启用 Upsample+Conv → Conv+PixelShuffle 改写（需先确认 ANE 回退）")
    args = parser.parse_args()

    print("=" * 60)
    print("RealESRGAN_x2 → Core ML（P2）")
    print(f"  12→3 通道: 启用")
    print(f"  PixelShuffle 改写: {'启用' if args.pixel_shuffle else '关闭'}")
    print("=" * 60)

    pth_path = download_model_weights()

    # ---- 1. 加载 12 通道模型 ----
    model_12 = load_model_12ch(pth_path)

    # ---- 2. 12 → 3 迁移 + 验证 ----
    print("\n[1/4] 12 通道 → 3 通道迁移")
    model_3 = copy.deepcopy(model_12)
    migrate_12ch_to_3ch(model_3)
    verify_12to3(model_12, model_3)

    # ---- 3. 可选：Upsample → PixelShuffle + 验证 ----
    if args.pixel_shuffle:
        print("\n[2/4] Upsample+Conv → Conv+PixelShuffle 改写")
        model_ps = copy.deepcopy(model_3)
        apply_pixelshuffle(model_ps)
        verify_pixelshuffle(model_3, model_ps, in_ch=3)
        final_model = model_ps
    else:
        print("\n[2/4] 跳过 PixelShuffle 改写")
        final_model = model_3

    final_model.eval()

    # ---- 4. 转换 ----
    print("\n[3/4] Core ML 转换")
    mlmodel = convert_to_coreml(final_model, in_channels=3)

    # ---- 5. 保存 ----
    print(f"\n[4/4] 保存到: {OUTPUT_PACKAGE}")
    mlmodel.save(OUTPUT_PACKAGE)
    total = sum(os.path.getsize(os.path.join(r, f))
                for r, _, fs in os.walk(OUTPUT_PACKAGE) for f in fs)
    print(f"✅ 完成，大小: {total / 1024 / 1024:.1f} MB")

    print("\n" + "=" * 60)
    print("后续：Swift 侧输入通道从 12 改成 3")
    print("  - bgraToTensor 的 channels==12 分支可以删掉")
    print("  - inputArray shape 由模型自动决定，无需手动改")
    print("=" * 60)


if __name__ == "__main__":
    main()
