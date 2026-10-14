import torch
import torch.nn as nn

if torch.cuda.is_available():
    device = torch.device("cuda")
elif torch.backends.mps.is_available():
    device = torch.device("mps")
else:
    device = torch.device("cpu")


def warp(tenInput, tenFlow):
    """
    可微光流 Warp：根据 tenFlow 对 tenInput 进行双线性采样
    注意：已移除全局 grid 缓存以兼容 TorchScript trace
    """
    flow_device = tenFlow.device
    batch_size = tenFlow.shape[0]
    height = tenFlow.shape[2]
    width = tenFlow.shape[3]

    # 直接计算采样网格（不使用全局缓存，兼容 TorchScript）
    tenHorizontal = torch.linspace(-1.0, 1.0, width, device=flow_device).view(
        1, 1, 1, width).expand(batch_size, -1, height, -1)
    tenVertical = torch.linspace(-1.0, 1.0, height, device=flow_device).view(
        1, 1, height, 1).expand(batch_size, -1, -1, width)
    tenGrid = torch.cat([tenHorizontal, tenVertical], 1)

    # 光流归一化到 [-1, 1] 坐标空间
    tenFlow_normalized = torch.cat([
        tenFlow[:, 0:1, :, :] / ((tenInput.shape[3] - 1.0) / 2.0),
        tenFlow[:, 1:2, :, :] / ((tenInput.shape[2] - 1.0) / 2.0)
    ], 1)

    g = (tenGrid + tenFlow_normalized).permute(0, 2, 3, 1)
    return torch.nn.functional.grid_sample(
        input=tenInput,
        grid=g,
        mode='bilinear',
        padding_mode='border',
        align_corners=True
    )
