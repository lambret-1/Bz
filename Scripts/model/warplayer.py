import torch
import torch.nn as nn

if torch.cuda.is_available():
    device = torch.device("cuda")
elif torch.backends.mps.is_available():
    device = torch.device("mps")
else:
    device = torch.device("cpu")

# 固定输入尺寸（Core ML 转换时使用），避免动态形状导致的 int op 转换问题
_WARP_WIDTH = 512
_WARP_HEIGHT = 512


def warp(tenInput, tenFlow):
    """
    可微光流 Warp：根据 tenFlow 对 tenInput 进行双线性采样
    注意：已移除全局 grid 缓存和动态形状计算，使用固定尺寸兼容 TorchScript/Core ML
    """
    flow_device = tenFlow.device
    batch_size = tenFlow.shape[0]

    # 使用固定尺寸预计算采样网格
    tenHorizontal = torch.linspace(-1.0, 1.0, _WARP_WIDTH, device=flow_device).view(
        1, 1, 1, _WARP_WIDTH).expand(batch_size, -1, _WARP_HEIGHT, -1)
    tenVertical = torch.linspace(-1.0, 1.0, _WARP_HEIGHT, device=flow_device).view(
        1, 1, _WARP_HEIGHT, 1).expand(batch_size, -1, -1, _WARP_WIDTH)
    tenGrid = torch.cat([tenHorizontal, tenVertical], 1)

    # 光流归一化到 [-1, 1] 坐标空间（使用固定尺寸常量）
    width_norm = (_WARP_WIDTH - 1.0) / 2.0
    height_norm = (_WARP_HEIGHT - 1.0) / 2.0
    tenFlow_normalized = torch.cat([
        tenFlow[:, 0:1, :, :] / width_norm,
        tenFlow[:, 1:2, :, :] / height_norm
    ], 1)

    g = (tenGrid + tenFlow_normalized).permute(0, 2, 3, 1)
    return torch.nn.functional.grid_sample(
        input=tenInput,
        grid=g,
        mode='bilinear',
        padding_mode='border',
        align_corners=True
    )
