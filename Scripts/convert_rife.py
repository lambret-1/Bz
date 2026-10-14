"""
RIFE Lite → Core ML 模型转换脚本

用途：将 RIFE Lite 的 PyTorch 权重转换为 iOS 端侧可用的 Core ML .mlpackage

使用方式：
    1. 获取 RIFE Lite 模型权重（见下方 load_rife_lite 函数注释）
    2. 在 macOS 上运行：python convert_rife.py
    3. 生成 RIFE_Lite.mlpackage，放入 App 的 Resources/ 目录

注意事项：
    - 必须在 macOS 上运行（coremltools 依赖 Apple 框架）
    - 转换后的模型为 mlprogram 格式，Float16 精度，可调用 ANE
    - 模型输入尺寸固定为 512x512，如需修改请同步修改 FrameInterpolator.swift
"""

import torch
import coremltools as ct
import numpy as np
import os
import sys


def load_rife_lite():
    """
    加载 RIFE Lite PyTorch 模型

    权重获取方式（三选一）：
    1. 官方仓库：https://github.com/hzwer/ECCV2022-RIFE
       - 下载 train_log 目录中的 RIFE Lite 权重
       - 使用 model.load_state_dict(torch.load('path/to/weight.pkl'))

    2. 社区预转换模型：搜索 "RIFE Lite Core ML" 或 "RIFE Lite mlmodel"
       - 部分社区已提供转换好的 .mlmodel，可直接使用

    3. Hugging Face：搜索 "RIFE" 相关模型仓库

    加载后需调用 model.eval() 并设置 device='cpu'

    TODO: 填入实际的模型加载逻辑
    示例代码：
        from model.RIFE_HDv3 import Model
        model = Model()
        model.load_model('path/to/train_log', -1)
        model.device()
        model.eval()
        return model
    """
    raise NotImplementedError(
        "请先获取 RIFE Lite 模型权重，并在 load_rife_lite() 中填入加载逻辑。\n"
        "权重可从官方仓库 https://github.com/hzwer/ECCV2022-RIFE 获取。"
    )


def convert():
    """执行模型转换"""
    print("🔄 开始转换 RIFE Lite 模型...")

    # 1. 加载模型
    model = load_rife_lite()
    print("✅ 模型加载成功")

    # 2. 固定输入尺寸（移动端建议 512x512，平衡速度与质量）
    H, W = 512, 512
    example_input_0 = torch.randn(1, 3, H, W)
    example_input_1 = torch.randn(1, 3, H, W)

    # 3. TorchScript Trace
    print("🔄 正在 TorchScript Trace...")
    traced = torch.jit.trace(model, (example_input_0, example_input_1))
    print("✅ Trace 完成")

    # 4. 转换为 Core ML
    print("🔄 正在转换为 Core ML...")
    mlmodel = ct.convert(
        traced,
        inputs=[
            ct.TensorType(name="frame0", shape=(1, 3, H, W)),
            ct.TensorType(name="frame1", shape=(1, 3, H, W)),
        ],
        outputs=[
            ct.TensorType(name="flow"),
            ct.TensorType(name="mask"),
        ],
        minimum_deployment_target=ct.target.iOS16,
        compute_precision=ct.precision.FLOAT16,
        convert_to="mlprogram",
    )

    # 5. 设置模型元数据
    mlmodel.author = "Bz"
    mlmodel.short_description = "RIFE Lite 视频帧插值模型，输入前后两帧，输出光流与掩码"
    mlmodel.versionString = "1.0"

    # 6. 保存
    output_path = os.path.join(os.path.dirname(__file__), "RIFE_Lite.mlpackage")
    mlmodel.save(output_path)
    print(f"✅ 转换完成：{output_path}")
    print(f"   输入尺寸：{H}x{W}")
    print(f"   精度：Float16")
    print(f"   最低系统：iOS 16")


if __name__ == "__main__":
    convert()
