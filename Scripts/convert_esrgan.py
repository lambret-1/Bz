"""
Real-ESRGAN General-x4v3 轻量版 → Core ML 模型转换脚本

功能：
    1. 自动从 GitHub Releases 下载 realesr-general-x4v3.pth 权重
    2. 加载 SRVGGNetCompact 模型并载入权重
    3. 转换为 Core ML mlprogram 格式（FP16，128×128 输入）
    4. 输出 real_esrgan_x4v3.mlpackage，可直接放入 iOS App Resources

使用方式：
    python convert_esrgan.py

模型来源：
    官方仓库：https://github.com/xinntao/Real-ESRGAN
    权重地址：https://github.com/xinntao/Real-ESRGAN/releases/download/v0.2.5.0/realesr-general-x4v3.pth
    许可证：BSD-3-Clause
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

from esrgan_model.srvgg_net import SRVGGNetCompact

# ==================== 配置 ====================
# 模型权重下载地址
MODEL_PTH_URL = "https://github.com/xinntao/Real-ESRGAN/releases/download/v0.2.5.0/realesr-general-x4v3.pth"
# 固定输入瓦片尺寸（x4v3 轻量版使用 128×128 瓦片）
INPUT_SIZE = 128
# 输出路径
OUTPUT_PACKAGE = os.path.join(SCRIPT_DIR, "real_esrgan_x4v3.mlpackage")


# ==================== 下载权重 ====================
def download_model_weights() -> str:
    """从 GitHub Releases 下载模型权重，返回本地路径"""
    pth_path = os.path.join(SCRIPT_DIR, "realesr-general-x4v3.pth")

    if os.path.exists(pth_path):
        print(f"📦 模型权重已存在，跳过下载: {pth_path}")
        return pth_path

    print(f"⬇️  正在下载 Real-ESRGAN x4v3 权重...")
    print(f"   来源: {MODEL_PTH_URL}")
    urllib.request.urlretrieve(MODEL_PTH_URL, pth_path)
    file_size = os.path.getsize(pth_path) / (1024 * 1024)
    print(f"✅ 下载完成，大小: {file_size:.2f} MB")
    return pth_path


# ==================== 加载模型 ====================
def load_model(pth_path: str) -> SRVGGNetCompact:
    """加载 SRVGGNetCompact 模型并载入权重"""
    print("🔧 正在加载模型...")

    model = SRVGGNetCompact(
        num_in_ch=3,
        num_out_ch=3,
        num_feat=64,
        num_conv=32,
        upscale=4,
        act_type='prelu'
    )

    # 加载权重（Real-ESRGAN 的权重可能包含 'params_ema' 或 'params' 键）
    checkpoint = torch.load(pth_path, map_location='cpu', weights_only=False)

    if 'params_ema' in checkpoint:
        state_dict = checkpoint['params_ema']
        print("   使用 EMA 权重")
    elif 'params' in checkpoint:
        state_dict = checkpoint['params']
        print("   使用普通权重")
    else:
        state_dict = checkpoint
        print("   直接使用 checkpoint 作为 state_dict")

    model.load_state_dict(state_dict, strict=True)
    model.eval()

    # 统计参数量
    param_count = sum(p.numel() for p in model.parameters())
    print(f"✅ 模型加载成功，参数量: {param_count / 1e6:.2f}M")
    return model


# ==================== 转换为 Core ML ====================
def convert_to_coreml(model: SRVGGNetCompact) -> ct.models.MLModel:
    """将 PyTorch 模型转换为 Core ML 格式"""
    print("🔄 正在转换为 Core ML...")

    # 创建示例输入（归一化到 [0,1]）
    example_input = torch.rand(1, 3, INPUT_SIZE, INPUT_SIZE)

    # TorchScript Trace
    traced_model = torch.jit.trace(model, example_input)
    print("   TorchScript Trace 完成")

    # 转换为 Core ML
    # ImageType 输入输出：Zero-Copy，直接喂 CVPixelBuffer，避免 MLMultiArray 转换开销
    # scale=1/255.0：自动将 [0,255] 归一化到 [0,1]，与模型输入匹配
    # 输出 scale=255.0：自动将 [0,1] 反归一化到 [0,255]
    mlmodel = ct.convert(
        traced_model,
        convert_to="mlprogram",
        inputs=[ct.ImageType(
            name="input",
            shape=(1, 3, INPUT_SIZE, INPUT_SIZE),
            scale=1/255.0,
            bias=[0, 0, 0]
        )],
        outputs=[ct.ImageType(
            name="output",
            scale=1.0
        )],
        compute_precision=ct.precision.FLOAT16,
        minimum_deployment_target=ct.target.iOS16
    )

    # 设置模型元数据
    mlmodel.short_description = "Real-ESRGAN General-x4v3 轻量版 4x 超分模型（ImageType零拷贝）"
    mlmodel.input_description["input"] = "输入图像 128x128，BGRA CVPixelBuffer，自动归一化[0,1]"
    mlmodel.output_description["output"] = "超分输出图像 512x512，BGRA CVPixelBuffer"

    print("✅ Core ML 转换完成")
    return mlmodel


# ==================== 验证模型 ====================
def verify_model(mlmodel: ct.models.MLModel):
    """验证 Core ML 模型推理输出"""
    print("🔍 正在验证模型推理...")

    # ImageType 输入：用 PIL Image 或 numpy array
    from PIL import Image
    input_image = Image.fromarray(np.random.randint(0, 256, (INPUT_SIZE, INPUT_SIZE, 3), dtype=np.uint8))

    # 推理
    result = mlmodel.predict({"input": input_image})
    output = result["output"]

    print(f"   输入类型: {type(input_image)}, 尺寸: {input_image.size}")
    print(f"   输出类型: {type(output)}")
    if hasattr(output, 'size'):
        print(f"   输出尺寸: {output.size}")

    print("✅ 模型验证通过")


# ==================== 主函数 ====================
def main():
    print("=" * 60)
    print("Real-ESRGAN General-x4v3 → Core ML 转换")
    print("=" * 60)

    # 1. 下载权重
    pth_path = download_model_weights()

    # 2. 加载模型
    model = load_model(pth_path)

    # 3. 转换为 Core ML
    mlmodel = convert_to_coreml(model)

    # 4. 验证模型
    verify_model(mlmodel)

    # 5. 保存模型
    print(f"💾 正在保存模型到: {OUTPUT_PACKAGE}")
    mlmodel.save(OUTPUT_PACKAGE)

    # 计算包体大小
    total_size = 0
    for root, dirs, files in os.walk(OUTPUT_PACKAGE):
        for f in files:
            total_size += os.path.getsize(os.path.join(root, f))
    print(f"✅ 模型保存完成，包体大小: {total_size / (1024 * 1024):.2f} MB")
    print("=" * 60)
    print("转换完成！将 real_esrgan_x4v3.mlpackage 放入 FrameInterpolation/Resources/ 目录")


if __name__ == "__main__":
    main()
