"""
Real-ESRGAN x4plus → Core ML 转换脚本 (伪装成 v3 文件名)
包含转换后的颜色验证逻辑，防止生成全黑模型
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
    
    if 'params_ema' in checkpoint:
        state_dict = checkpoint['params_ema']
    elif 'params' in checkpoint:
        state_dict = checkpoint['params']
    else:
        state_dict = checkpoint

    model.load_state_dict(state_dict, strict=True)
    model.eval()
    
    del checkpoint, state_dict
    gc.collect()
    
    return model

def convert_to_coreml(pth_path: str) -> ct.models.MLModel:
    print(f"🔄 转换为 Core ML（输入: {INPUT_WIDTH}x{INPUT_HEIGHT}）...")
    
    model = load_model(pth_path)
    example_input = torch.rand(1, 3, INPUT_HEIGHT, INPUT_WIDTH)
    
    print("   正在进行 TorchScript Trace...")
    with torch.no_grad():
        traced_model = torch.jit.trace(model, example_input)

    print("   💥 释放原始 PyTorch 模型内存...")
    del model
    gc.collect()

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
        outputs=[ct.ImageType(name="output", scale=255.0)],
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
    print("✅ 模型保存成功！")

    # ==================== 预言验证代码开始 ====================
    print("🔍 开始验证模型输出像素（防止全黑）...")
    try:
        from PIL import Image
        
        # 制造一张纯灰色的测试图 (RGB: 128,128,128)
        # 注意 PIL size 是 (宽, 高)
        test_img = Image.fromarray(np.full((INPUT_HEIGHT, INPUT_WIDTH, 3), 128, dtype=np.uint8))
        
        # 推理
        test_out = mlmodel.predict({"input": test_img})["output"]
        
        # 转成 numpy 分析像素
        test_arr = np.array(test_out)
        
        print(f"   输出尺寸: {test_out.size}")
        print(f"   像素最小值: {test_arr.min()}, 最大值: {test_arr.max()}, 平均值: {test_arr.mean():.2f}")
        
        if test_arr.max() == 0:
            print("❌ 警告: 模型输出全黑！转换失败！请检查模型转换配置！")
        elif test_arr.max() < 10:
            print("⚠️ 警告: 模型输出极暗，可能存在异常！")
        else:
            print("✅ 模型输出正常，不是全黑。")
            
    except Exception as e:
        print(f"❌ 验证阶段发生错误: {e}")
    # ==================== 预言验证代码结束 ====================

if __name__ == "__main__":
    main()
