"""
Fast-SRGAN → Core ML 模型转换脚本

功能：
    1. 自动从 GitHub 下载 Fast-SRGAN 权重（model.pt）
    2. 加载 Generator 模型并载入权重
    3. 包装为 [0,1] 输入输出（内部转换为 [-1,1] 供模型使用）
    4. TorchScript Trace 后转换为 Core ML mlprogram 格式（FP16）
    5. 输出 fast_srgan.mlpackage，可直接放入 iOS App Resources

使用方式：
    python convert_fast_srgan.py

模型来源：
    官方仓库：https://github.com/HasnainRaz/Fast-SRGAN
    权重地址：https://raw.githubusercontent.com/HasnainRaz/Fast-SRGAN/master/models/model.pt
    许可证：MIT
"""

import os
import sys
import urllib.request
import torch
import torch.nn as nn
import coremltools as ct
import numpy as np

# 将 Scripts 目录加入路径
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, SCRIPT_DIR)

from fast_srgan_model.generator import FastSRGANGenerator

# ==================== 配置 ====================
# 模型权重下载地址
MODEL_PT_URL = "https://raw.githubusercontent.com/HasnainRaz/Fast-SRGAN/master/models/model.pt"
# 固定输入瓦片尺寸（平衡速度与质量）
INPUT_SIZE = 128
# 输出路径
OUTPUT_PACKAGE = os.path.join(SCRIPT_DIR, "fast_srgan.mlpackage")


# ==================== 模型包装器 ====================
class FastSRGANWrapper(nn.Module):
    """
    Fast-SRGAN 推理包装器：处理 [0,1] ↔ [-1,1] 归一化转换

    输入：img [B, 3, H, W]，归一化到 [0, 1]，RGB 顺序
    输出：out [B, 3, H*4, W*4]，归一化到 [0, 1]，RGB 顺序

    内部：输入 *2-1 → [-1,1] → Generator → Tanh输出[-1,1] → (输出+1)/2 → [0,1]
    """

    def __init__(self, generator: FastSRGANGenerator):
        super().__init__()
        self.generator = generator

    def forward(self, x: torch.Tensor):
        # [0,1] → [-1,1]
        x = x * 2.0 - 1.0
        # 推理
        out = self.generator(x)
        # [-1,1] → [0,1]
        out = (out + 1.0) / 2.0
        return out


# ==================== 下载权重 ====================
def download_model_weights() -> str:
    """从 GitHub 下载模型权重，返回本地路径"""
    pt_path = os.path.join(SCRIPT_DIR, "fast_srgan_model.pt")

    if os.path.exists(pt_path):
        print(f"📦 模型权重已存在，跳过下载: {pt_path}")
        return pt_path

    print(f"⬇️  正在下载 Fast-SRGAN 权重...")
    print(f"   来源: {MODEL_PT_URL}")
    urllib.request.urlretrieve(MODEL_PT_URL, pt_path)
    file_size = os.path.getsize(pt_path) / (1024 * 1024)
    print(f"✅ 下载完成，大小: {file_size:.2f} MB")
    return pt_path


# ==================== 加载模型 ====================
def load_model(pt_path: str) -> FastSRGANWrapper:
    """加载 Fast-SRGAN 模型并载入权重"""
    print("🔧 正在加载模型...")

    generator = FastSRGANGenerator(n_filters=64, n_layers=8)

    # 加载权重
    checkpoint = torch.load(pt_path, map_location='cpu', weights_only=False)

    # Fast-SRGAN 的 checkpoint 可能直接是 state_dict，也可能包含 'generator' 键
    if isinstance(checkpoint, dict) and 'generator' in checkpoint:
        state_dict = checkpoint['generator']
        print("   从 'generator' 键加载权重")
    elif isinstance(checkpoint, dict) and 'state_dict' in checkpoint:
        state_dict = checkpoint['state_dict']
        print("   从 'state_dict' 键加载权重")
    else:
        state_dict = checkpoint
        print("   直接使用 checkpoint 作为 state_dict")

    # 尝试加载，忽略不匹配的键（如 discriminator 相关）
    generator.load_state_dict(state_dict, strict=False)
    generator.eval()

    # 包装为 [0,1] 输入输出
    model = FastSRGANWrapper(generator)
    model.eval()

    # 统计参数量
    param_count = sum(p.numel() for p in model.parameters())
    print(f"✅ 模型加载成功，参数量: {param_count / 1e6:.2f}M")
    return model


# ==================== 转换为 Core ML ====================
def convert_to_coreml(model: FastSRGANWrapper) -> ct.models.MLModel:
    """将 PyTorch 模型转换为 Core ML 格式"""
    print("🔄 正在转换为 Core ML...")

    # 创建示例输入（归一化到 [0,1]）
    example_input = torch.rand(1, 3, INPUT_SIZE, INPUT_SIZE)

    # TorchScript Trace
    traced_model = torch.jit.trace(model, example_input)
    print("   TorchScript Trace 完成")

    # 转换为 Core ML
    mlmodel = ct.convert(
        traced_model,
        convert_to="mlprogram",
        inputs=[ct.TensorType(name="input", shape=(1, 3, INPUT_SIZE, INPUT_SIZE))],
        outputs=[ct.TensorType(name="output")],
        compute_precision=ct.precision.FLOAT16,
        minimum_deployment_target=ct.target.iOS16
    )

    # 设置模型元数据
    mlmodel.short_description = "Fast-SRGAN 4x 超分模型（轻量快速版）"
    mlmodel.input_description["input"] = "输入图像 [1,3,128,128]，归一化到 [0,1]，RGB 顺序"
    mlmodel.output_description["output"] = "超分输出图像 [1,3,512,512]，归一化到 [0,1]，RGB 顺序"

    print("✅ Core ML 转换完成")
    return mlmodel


# ==================== 验证模型 ====================
def verify_model(mlmodel: ct.models.MLModel):
    """验证 Core ML 模型推理输出"""
    print("🔍 正在验证模型推理...")

    # 创建随机输入
    input_array = np.random.rand(1, 3, INPUT_SIZE, INPUT_SIZE).astype(np.float32)

    # 推理
    result = mlmodel.predict({"input": input_array})
    output = result["output"]

    print(f"   输入形状: {input_array.shape}")
    print(f"   输出形状: {output.shape}")
    print(f"   输出范围: [{output.min():.4f}, {output.max():.4f}]")

    expected_shape = (1, 3, INPUT_SIZE * 4, INPUT_SIZE * 4)
    if output.shape == expected_shape:
        print("✅ 模型验证通过，输出形状正确")
    else:
        print(f"⚠️  输出形状不匹配，期望: {expected_shape}，实际: {output.shape}")


# ==================== 主函数 ====================
def main():
    print("=" * 60)
    print("Fast-SRGAN → Core ML 转换")
    print("=" * 60)

    # 1. 下载权重
    pt_path = download_model_weights()

    # 2. 加载模型
    model = load_model(pt_path)

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
    print("转换完成！将 fast_srgan.mlpackage 放入 FrameInterpolation/Resources/ 目录")


if __name__ == "__main__":
    main()
