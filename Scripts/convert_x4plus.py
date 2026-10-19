"""
Real-ESRGAN x4plus → Core ML 转换脚本 (伪装成 v3 文件名)
针对 GitHub Actions 内存限制进行了极限优化
"""

import os
import sys
import gc
import urllib.request
import torch
import coremltools as ct
import numpy as np

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, SCRIPT_DIR)

try:
    from basicsr.archs.rrdbnet_arch import RRDBNet
except ImportError:
    print("❌ 缺少 basicsr 库，请先运行: pip install basicsr-fixed")
    sys.exit(1)

# ==================== 配置 ====================
MODEL_PTH_URL = "https://github.com/xinntao/Real-ESRGAN/releases/download/v0.1.0/RealESRGAN_x4plus.pth"
INPUT_WIDTH = 352
INPUT_HEIGHT = 608

# 伪装文件名：输出依然叫 v3
OUTPUT_PACKAGE = os.path.join(SCRIPT_DIR, "real_esrgan_x4v3.mlpackage")

def download_model_weights() -> str:
    pth_path = os.path.join(SCRIPT_DIR, "RealESRGAN_x4plus.pth")
    if os.path.exists(pth_path):
        return pth_path
    print(f"⬇️ 正在下载 x4plus 权重...")
    urllib.request.urlretrieve(MODEL_PTH_URL, pth_path)
    return pth_path

def load_model(pth_path: str) -> RRDBNet:
    print("🔧 正在加载 x4plus (RRDBNet)...")
    model = RRDBNet(num_in_ch=3, num_out_ch=3, num_feat=64, num_block=23, num_grow_ch=32, scale=4)
    checkpoint = torch.load(pth_path, map_location='cpu', weights_only=False)
    
    # 安全地提取权重字典
    if 'params_ema' in checkpoint:
        state_dict = checkpoint['params_ema']
    elif 'params' in checkpoint:
        state_dict = checkpoint['params']
    else:
        state_dict = checkpoint

    model.load_state_dict(state_dict, strict=True)
    model.eval()
    
    # 清理 checkpoint 释放内存
    del checkpoint, state_dict
    gc.collect()
    
    return model

def convert_to_coreml(pth_path: str) -> ct.models.MLModel:
    print(f"🔄 转换为 Core ML（输入: {INPUT_WIDTH}x{INPUT_HEIGHT}）...")
    
    model = load_model(pth_path)
    
    # 1. 构造假输入并 Trace
    example_input = torch.rand(1, 3, INPUT_HEIGHT, INPUT_WIDTH)
    print("   正在进行 TorchScript Trace...")
    with torch.no_grad():
        traced_model = torch.jit.trace(model, example_input)

    # 2. 【核心内存优化】销毁原始模型，强制垃圾回收
    # 在 Trace 之后，原始模型就不需要了，这能释放数百 MB 到 GB 的内存
    print("   💥 释放原始 PyTorch 模型内存...")
    del model
    gc.collect()

    # 3. 开始 CoreML 转换
    print("   开始 CoreML 图优化与转换（极耗内存，请稍候）...")
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
    
    mlmodel.short_description = "Real-ESRGAN x4plus (伪装为v3)"
    return mlmodel

def main():
    pth_path = download_model_weights()
    mlmodel = convert_to_coreml(pth_path)
    
    print(f"💾 保存模型到: {OUTPUT_PACKAGE}")
    mlmodel.save(OUTPUT_PACKAGE)
    print("✅ 转换完成！")

if __name__ == "__main__":
    main()
