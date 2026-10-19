import torch
from basicsr.archs.rrdbnet_arch import RRDBNet
import coremltools as ct

# 1. 初始化 RRDBNet 架构
model = RRDBNet(num_in_ch=3, num_out_ch=3, num_feat=64, num_block=23, num_grow_ch=32, scale=4)

# 2. 加载官方权重（下载 RealESRGAN_x4plus.pth）
checkpoint = torch.load("RealESRGAN_x4plus.pth", map_location='cpu')
model.load_state_dict(checkpoint['params_ema'], strict=True)
model.eval()

# 3. Trace 和转换（注意输入尺寸依然是 608 高，352 宽）
example_input = torch.rand(1, 3, 608, 352)
traced_model = torch.jit.trace(model, example_input)

mlmodel = ct.convert(
    traced_model,
    convert_to="mlprogram",
    inputs=[ct.ImageType(name="input", shape=(1, 3, 608, 352), scale=1/255.0)],
    outputs=[ct.ImageType(name="output", scale=1.0)],
    compute_precision=ct.precision.FLOAT16,
    minimum_deployment_target=ct.target.iOS16
)

# 保存为新名字
mlmodel.save("real_esrgan_x4plus.mlpackage")