"""
RIFE 4.22 Lite → Core ML 模型转换脚本

功能：
    1. 自动从 Hugging Face 下载 RIFE 4.22 Lite 权重
    2. 加载 IFNet 模型并载入权重
    3. 包装为固定输入输出的推理模型（timestep=0.5, 2x 补帧）
    4. TorchScript Trace 后转换为 Core ML mlprogram 格式
    5. 输出 RIFE_Lite.mlpackage，可直接放入 iOS App Resources

使用方式：
    python convert_rife.py

模型来源：
    官方仓库：https://github.com/hzwer/Practical-RIFE
    权重镜像：https://huggingface.co/anon0077/RIFE-Models (RIFE_v4.22.lite.zip)
    许可证：MIT
"""

import os
import sys
import zipfile
import urllib.request
import torch
import torch.nn as nn
import coremltools as ct
import numpy as np

# 将 Scripts 目录加入路径，以便导入 model 包
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, SCRIPT_DIR)

from model.IFNet_HDv3 import IFNet

# ==================== 配置 ====================
# 模型权重下载地址（Hugging Face 镜像）
MODEL_ZIP_URL = "https://huggingface.co/anon0077/RIFE-Models/resolve/main/RIFE_v4.22.lite.zip"
# 固定输入尺寸（必须为 16 的倍数，512 平衡速度与质量）
INPUT_HEIGHT = 512
INPUT_WIDTH = 512
# 输出路径
OUTPUT_PACKAGE = os.path.join(SCRIPT_DIR, "RIFE_Lite.mlpackage")


# ==================== 模型包装器 ====================
class RIFEWrapper(nn.Module):
    """
    RIFE 推理包装器：固定 timestep=0.5 和 scale_list，输出中间帧
    输入：img0 [B, 3, H, W], img1 [B, 3, H, W]（归一化到 [0, 1]）
    输出：merged [B, 3, H, W]（中间帧，归一化到 [0, 1]）
    """
    def __init__(self, flownet: IFNet):
        super().__init__()
        self.flownet = flownet

    def forward(self, img0: torch.Tensor, img1: torch.Tensor) -> torch.Tensor:
        # 拼接前后帧
        imgs = torch.cat((img0, img1), dim=1)
        # 固定时间步（0.5 = 正中间）
        timestep = 0.5
        # 固定多尺度列表
        scale_list = [8.0, 4.0, 2.0, 1.0]
        # 推理
        flow_list, mask, merged = self.flownet(imgs, timestep, scale_list)
        # merged[3] 是最终融合的中间帧
        return merged[3]


# ==================== 下载权重 ====================
def download_model_zip() -> str:
    """从 Hugging Face 下载模型权重 ZIP，返回本地路径"""
    zip_path = os.path.join(SCRIPT_DIR, "RIFE_v4.22.lite.zip")

    if os.path.exists(zip_path):
        print(f"📦 模型权重已存在，跳过下载: {zip_path}")
        return zip_path

    print(f"⬇️  正在下载 RIFE 4.22 Lite 权重...")
    print(f"   来源: {MODEL_ZIP_URL}")

    def progress_hook(block_num, block_size, total_size):
        downloaded = block_num * block_size
        percent = min(downloaded / total_size * 100, 100)
        mb_downloaded = downloaded / 1024 / 1024
        mb_total = total_size / 1024 / 1024
        print(f"\r   进度: {percent:.1f}% ({mb_downloaded:.1f}/{mb_total:.1f} MB)", end="", flush=True)

    urllib.request.urlretrieve(MODEL_ZIP_URL, zip_path, progress_hook)
    print(f"\n✅ 下载完成: {zip_path}")
    return zip_path


def extract_flownet_pkl(zip_path: str) -> str:
    """从 ZIP 中提取 flownet.pkl，返回权重文件路径"""
    pkl_path = os.path.join(SCRIPT_DIR, "flownet.pkl")

    if os.path.exists(pkl_path):
        print(f"📦 flownet.pkl 已存在，跳过解压")
        return pkl_path

    print(f"📦 正在解压模型权重...")
    with zipfile.ZipFile(zip_path, 'r') as zf:
        # 查找 train_log/flownet.pkl
        pkl_members = [m for m in zf.namelist() if m.endswith('flownet.pkl')]
        if not pkl_members:
            raise FileNotFoundError("ZIP 中未找到 flownet.pkl")

        # 解压到 Scripts 目录
        with zf.open(pkl_members[0]) as src, open(pkl_path, 'wb') as dst:
            dst.write(src.read())

    print(f"✅ 解压完成: {pkl_path}")
    return pkl_path


# ==================== 加载模型 ====================
def load_model(pkl_path: str) -> RIFEWrapper:
    """加载 IFNet 模型并载入权重，返回包装器"""
    print(f"🔧 正在加载模型...")

    # 创建模型
    flownet = IFNet()
    flownet.eval()

    # 加载权重
    state_dict = torch.load(pkl_path, map_location='cpu')

    # 处理可能的 module. 前缀（DDP 训练时的前缀）
    new_state_dict = {}
    for k, v in state_dict.items():
        new_key = k.replace("module.", "") if k.startswith("module.") else k
        new_state_dict[new_key] = v

    # 严格加载，允许部分缺失（非推理用的 teacher 网络等）
    result = flownet.load_state_dict(new_state_dict, strict=False)
    if result.missing_keys:
        print(f"⚠️  缺失的权重键（可能是非推理用参数）: {len(result.missing_keys)} 个")
    if result.unexpected_keys:
        print(f"⚠️  多余的权重键: {len(result.unexpected_keys)} 个")

    # 包装
    model = RIFEWrapper(flownet)
    model.eval()

    print(f"✅ 模型加载成功")
    return model


# ==================== 转换为 Core ML ====================
def convert_to_coreml(model: RIFEWrapper) -> ct.models.MLModel:
    """将 PyTorch 模型转换为 Core ML mlprogram 格式"""
    print(f"🔄 正在 TorchScript Trace...")
    print(f"   输入尺寸: {INPUT_WIDTH}x{INPUT_HEIGHT}")

    # 创建示例输入
    example_input_0 = torch.randn(1, 3, INPUT_HEIGHT, INPUT_WIDTH)
    example_input_1 = torch.randn(1, 3, INPUT_HEIGHT, INPUT_WIDTH)

    # Trace
    traced = torch.jit.trace(model, (example_input_0, example_input_1))
    print(f"✅ Trace 完成")

    # 验证输出形状
    with torch.no_grad():
        output = traced(example_input_0, example_input_1)
    print(f"   输出形状: {output.shape}")
    assert output.shape == (1, 3, INPUT_HEIGHT, INPUT_WIDTH), f"输出形状异常: {output.shape}"

    print(f"🔄 正在转换为 Core ML...")
    mlmodel = ct.convert(
        traced,
        inputs=[
            ct.TensorType(name="frame0", shape=(1, 3, INPUT_HEIGHT, INPUT_WIDTH)),
            ct.TensorType(name="frame1", shape=(1, 3, INPUT_HEIGHT, INPUT_WIDTH)),
        ],
        outputs=[
            ct.TensorType(name="interpolatedFrame"),
        ],
        minimum_deployment_target=ct.target.iOS16,
        compute_precision=ct.precision.FLOAT16,
        convert_to="mlprogram",
    )

    # 设置模型元数据
    mlmodel.author = "Bz"
    mlmodel.short_description = "RIFE 4.22 Lite 视频帧插值模型，输入前后两帧，输出中间帧"
    mlmodel.versionString = "4.22.lite"
    mlmodel.input_description["frame0"] = "前一帧，RGB 归一化到 [0, 1]，NCHW 布局，512x512"
    mlmodel.input_description["frame1"] = "后一帧，RGB 归一化到 [0, 1]，NCHW 布局，512x512"
    mlmodel.output_description["interpolatedFrame"] = "中间帧，RGB 归一化到 [0, 1]，NCHW 布局，512x512"

    print(f"✅ Core ML 转换完成")
    return mlmodel


# ==================== 主流程 ====================
def main():
    print("=" * 60)
    print("RIFE 4.22 Lite → Core ML 模型转换")
    print("=" * 60)

    # 1. 下载权重
    zip_path = download_model_zip()

    # 2. 解压权重
    pkl_path = extract_flownet_pkl(zip_path)

    # 3. 加载模型
    model = load_model(pkl_path)

    # 4. 转换为 Core ML
    mlmodel = convert_to_coreml(model)

    # 5. 保存
    print(f"💾 正在保存模型到: {OUTPUT_PACKAGE}")
    mlmodel.save(OUTPUT_PACKAGE)
    print(f"✅ 模型已保存: {OUTPUT_PACKAGE}")

    # 6. 验证
    print(f"\n🔍 验证模型规格:")
    print(f"   输入: frame0 [1, 3, {INPUT_HEIGHT}, {INPUT_WIDTH}], frame1 [1, 3, {INPUT_HEIGHT}, {INPUT_WIDTH}]")
    print(f"   输出: interpolatedFrame [1, 3, {INPUT_HEIGHT}, {INPUT_WIDTH}]")
    print(f"   精度: Float16")
    print(f"   最低系统: iOS 16")
    print(f"   格式: mlprogram")

    print(f"\n🎉 转换完成！")
    print(f"   将 {OUTPUT_PACKAGE} 复制到 FrameInterpolation/Resources/ 目录")
    print(f"   重新构建 App 即可启用真实 AI 补帧")


if __name__ == "__main__":
    main()
