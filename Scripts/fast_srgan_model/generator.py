"""
Fast-SRGAN Generator 模型定义

来源：https://github.com/HasnainRaz/Fast-SRGAN/blob/master/model.py
仅包含 Generator（推理用），移除 VGG19 和 Discriminator。
4x 超分，Tanh 输出（范围 [-1, 1]，需转换到 [0, 1]）。
"""

import torch
import torch.nn as nn


class UpSamplingBlock(nn.Module):
    """上采样块：Conv2d + PixelShuffle(2x) + PReLU"""

    def __init__(self, n_filters: int):
        super().__init__()
        self.conv = nn.Conv2d(
            in_channels=n_filters,
            out_channels=n_filters * 4,
            kernel_size=3,
            padding=1,
        )
        self.phase_shift = nn.PixelShuffle(upscale_factor=2)
        self.relu = nn.PReLU()

    def forward(self, x):
        return self.relu(self.phase_shift(self.conv(x)))


class ResidualBlock(nn.Module):
    """残差块：Conv2d + InstanceNorm2d + PReLU + Conv2d + InstanceNorm2d + 残差连接"""

    def __init__(self, in_channels: int, out_channels: int):
        super().__init__()
        self.conv1 = nn.Conv2d(
            in_channels=in_channels,
            out_channels=out_channels,
            kernel_size=3,
            stride=1,
            padding=1,
            bias=False,
        )
        self.bn1 = nn.InstanceNorm2d(out_channels)
        self.relu1 = nn.PReLU()
        self.conv2 = nn.Conv2d(
            in_channels=in_channels,
            out_channels=out_channels,
            kernel_size=3,
            stride=1,
            padding=1,
            bias=False,
        )
        self.bn2 = nn.InstanceNorm2d(out_channels)

    def forward(self, x):
        y = self.relu1(self.bn1(self.conv1(x)))
        return self.bn2(self.conv2(y)) + x


class FastSRGANGenerator(nn.Module):
    """Fast-SRGAN 生成器：4x 超分，Tanh 输出

    Args:
        n_filters (int): 中间特征通道数，默认 64
        n_layers (int): 残差块数量，默认 8
    """

    def __init__(self, n_filters: int = 64, n_layers: int = 8):
        super().__init__()
        self.n_filters = n_filters
        self.n_layers = n_layers

        # 颈部：初始卷积 + PReLU
        self.neck = nn.Sequential(
            nn.Conv2d(in_channels=3, out_channels=n_filters, kernel_size=3, padding=1),
            nn.PReLU(),
        )

        # 主干：多个残差块
        self.stem = nn.Sequential(
            *[
                ResidualBlock(in_channels=n_filters, out_channels=n_filters)
                for _ in range(n_layers)
            ]
        )

        # 瓶颈：卷积 + InstanceNorm
        self.bottleneck = nn.Sequential(
            nn.Conv2d(
                in_channels=n_filters,
                out_channels=n_filters,
                kernel_size=3,
                padding=1,
                bias=False,
            ),
            nn.InstanceNorm2d(n_filters),
        )

        # 上采样：2 个 2x 上采样块 = 4x 总放大
        self.upsampling = nn.Sequential(
            UpSamplingBlock(n_filters),
            UpSamplingBlock(n_filters),
        )

        # 头部：输出卷积 + Tanh（范围 [-1, 1]）
        self.head = nn.Sequential(
            nn.Conv2d(in_channels=n_filters, out_channels=3, kernel_size=3, padding=1),
            nn.Tanh(),
        )

    def forward(self, x):
        residual = self.neck(x)
        x = self.stem(residual)
        x = self.bottleneck(x) + residual
        x = self.upsampling(x)
        return self.head(x)
