import os
import sys
import gc
import urllib.request
import torch
import torch.nn as nn
import coremltools as ct
import numpy as np

# ... 前面的配置和下载代码保持不变 ...

def load_model(pth_path: str) -> nn.Module:
    print("🔧 正在加载 x4plus (RRDBNet)...")
    from basicsr.archs.rrdbnet_arch import RRDBNet
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
    
    # ==================== 核心修复：包装模型 ====================
    class WrappedModel(nn.Module):
        def __init__(self, original_model):
            super().__init__()
            self.original_model = original_model

        def forward(self, x):
            # 原始模型输出范围是 0~1，这里乘以 255 变成 0~255
            out = self.original_model(x)
            out = torch.clamp(out * 255.0, 0.0, 255.0)
            return out

    wrapped_model = WrappedModel(model).eval()
    # ==========================================================
    
    del checkpoint, state_dict
    gc.collect()
    
    return wrapped_model # 返回包装后的模型

def convert_to_coreml(pth_path: str) -> ct.models.MLModel:
    print(f"🔄 转换为 Core ML（输入: {INPUT_WIDTH}x{INPUT_HEIGHT}）...")
    
    model = load_model(pth_path) # 这里拿到的是 WrappedModel
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
        # 输出层强制改回 scale=1.0
        outputs=[ct.ImageType(name="output", scale=1.0)],
        compute_precision=ct.precision.FLOAT16,
        minimum_deployment_target=ct.target.iOS16
    )
    
    mlmodel.short_description = "Real-ESRGAN x4plus (伪装为v3)"
    return mlmodel

# ... 后面的验证代码和 main 函数保持不变 ...
