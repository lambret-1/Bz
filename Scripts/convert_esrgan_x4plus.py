"""
Real-ESRGAN x4plus → Core ML 模型转换脚

功能：
    1. 自动下载 RealESRGAN_x4plus.pth 权重
    2. 加载 RRDBNet 模型（23个 RRDB 块）
    3. 转换为 Core ML mlprogram 格式（FP16，宽352 x 高608 输入）
    4. 输出 real_esrgan_x4plus.mlpackage

依赖环境：
    pip install torch coremltools>=7.0 numpy Pillow basicsr
"""

import os
import sys
import urllib.request
import torch
import coremltools as ct
import numpy as np

# 将 Scripts 目录加入路径
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, SCRIPT_DIR)

# 注意：x4plus 需要从 basicsr 库导入 RRDBNet
try:
    from basicsr.archs.rrdbnet_arch import RRDBNet
except ImportError:
    print("❌ 缺少 basicsr 库，请先运行: pip install basicsr")
    sys.exit(1)

# ==================== 配置 ====================
MODEL_PTH_URL = "https://github.com/xinntao/Real-ESRGAN/releases/download/v0.2.5.0/RealESRGAN_x4plus.pth"
INPUT_WIDTH = 352
INPUT_HEIGHT = 608
OUTPUT_PACKAGE = os.path.join(SCRIPT_DIR, "real_esrgan_x4plus.mlpackage")


def download_model_weights() -> str:
    pth_path = os.path.join(SCRIPT_DIR, "RealESRGAN_x4plus.pth")

    if os.path.exists(pth_path):
        print(f"📦 模型权重已存在，跳过下载: {pth_path}")
        return pth_path

    print(f"⬇️  正在下载 Real-ESRGAN x4plus 权重...")
    print(f"   来源: {MODEL_PTH_URL}")
    urllib.request.urlretrieve(MODEL_PTH_URL, pth_path)
    file_size = os.path.getsize(pth_path) / (1024 * 1024)
    print(f"✅ 下载完成，大小: {file_size:.2f} MB")
    return pth_path


def load_model(pth_path: str) -> RRDBNet:
    print("🔧 正在加载 x4plus 模型 (RRDBNet)...")

    # 初始化 RRDBNet
    model = RRDBNet(num_in_ch=3, num_out_ch=3, num_feat=64, num_block=23, num_grow_ch=32, scale=4)

    checkpoint = torch.load(pth_path, map_location='cpu', weights_only=False)

    if 'params_ema' in checkpoint:
        state_dict = checkpoint['params_ema']
        print("   使用 EMA 权重")
    elif 'params' in checkpoint:
        state_dict = checkpoint['params']
        print("   使用普通权重")
    else:
        state_dict = checkpoint

    model.load_state_dict(state_dict, strict=True)
    model.eval()

    param_count = sum(p.numel() for p in model.parameters())
    print(f"✅ 模型加载成功，参数量: {param_count / 1e6:.2f}M")
    return model


def convert_to_coreml(model: RRDBNet) -> ct.models.MLModel:
    print(f"🔄 正在转换为 Core ML（输入尺寸: 宽{INPUT_WIDTH} x 高{INPUT_HEIGHT}）...")
    print("   注意：RRDBNet 结构复杂，转换可能需要几分钟，请耐心等待...")

    example_input = torch.rand(1, 3, INPUT_HEIGHT, INPUT_WIDTH)

    # Trace
    traced_model = torch.jit.trace(model, example_input)
    print("   TorchScript Trace 完成")

    mlmodel = ct.convert(
        traced_model,
        convert_to="mlprogram",
        inputs=[ct.ImageType(
            name="input",
            shape=(1, 3, INPUT_HEIGHT, INPUT_WIDTH),
            scale=1/255.0,
            bias=[0, 0, 0]
        )],
        outputs=[ct.ImageType(name="output", scale=1.0)],
        compute_precision=ct.precision.FLOAT16,
        minimum_deployment_target=ct.target.iOS16
    )

    mlmodel.short_description = f"Real-ESRGAN x4plus 4x 超分模型（{INPUT_WIDTH}x{INPUT_HEIGHT}）"
    mlmodel.input_description["input"] = "输入图像 352x608，自动归一化[0,1]"
    mlmodel.output_description["output"] = "输出图像 1408x2432"

    print("✅ Core ML 转换完成")
    return mlmodel


def verify_model(mlmodel: ct.models.MLModel):
    print("🔍 正在验证模型推理...")
    from PIL import Image
    input_image = Image.fromarray(np.random.randint(0, 256, (INPUT_HEIGHT, INPUT_WIDTH, 3), dtype=np.uint8))
    result = mlmodel.predict({"input": input_image})
    output = result["output"]
    print(f"   输入尺寸: {input_image.size}")
    if hasattr(output, 'size'):
        print(f"   输出尺寸: {output.size}")
    print("✅ 模型验证通过")


def main():
    print("=" * 60)
    print(f"Real-ESRGAN x4plus → Core ML 转换 (尺寸: {INPUT_WIDTH}x{INPUT_HEIGHT})")
    print("=" * 60)

    pth_path = download_model_weights()
    model = load_model(pth_path)
    mlmodel = convert_to_coreml(model)
    verify_model(mlmodel)

    print(f"💾 正在保存模型到: {OUTPUT_PACKAGE}")
    mlmodel.save(OUTPUT_PACKAGE)

    total_size = 0
    for root, dirs, files in os.walk(OUTPUT_PACKAGE):
        for f in files:
            total_size += os.path.getsize(os.path.join(root, f))
    print(f"✅ 模型保存完成，包体大小: {total_size / (1024 * 1024):.2f} MB")
    print("=" * 60)
    print("转换完成！请将 real_esrgan_x4plus.mlpackage 放入 FrameInterpolation/Resources/ 目录。")


if __name__ == "__main__":
    main()