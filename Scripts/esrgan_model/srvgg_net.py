"""
SRVGGNetCompact 模型定义（Real-ESRGAN x4v3 轻量版）

来源：https://github.com/xinntao/Real-ESRGAN/blob/master/realesrgan/archs/srvgg_arch.py
移除 basicsr 依赖，独立可运行。
"""

import torch
import torch.nn as nn
import torch.nn.functional as F


class SRVGGNetCompact(nn.Module):
    """轻量级 VGG 风格超分网络，最后一层上采样，HR 特征空间不做卷积。

    Args:
        num_in_ch (int): 输入通道数，默认 3
        num_out_ch (int): 输出通道数，默认 3
        num_feat (int): 中间特征通道数，默认 64
        num_conv (int): 主体卷积层数，默认 16
        upscale (int): 上采样倍数，默认 4
        act_type (str): 激活函数类型，默认 prelu
    """

    def __init__(self, num_in_ch=3, num_out_ch=3, num_feat=64, num_conv=16, upscale=4, act_type='prelu'):
        super(SRVGGNetCompact, self).__init__()
        self.num_in_ch = num_in_ch
        self.num_out_ch = num_out_ch
        self.num_feat = num_feat
        self.num_conv = num_conv
        self.upscale = upscale
        self.act_type = act_type

        self.body = nn.ModuleList()
        # 第一个卷积
        self.body.append(nn.Conv2d(num_in_ch, num_feat, 3, 1, 1))
        # 第一个激活
        self.body.append(self._make_activation(act_type, num_feat))

        # 主体结构
        for _ in range(num_conv):
            self.body.append(nn.Conv2d(num_feat, num_feat, 3, 1, 1))
            self.body.append(self._make_activation(act_type, num_feat))

        # 最后一个卷积（输出通道数 = num_out_ch * upscale^2，供 PixelShuffle 使用）
        self.body.append(nn.Conv2d(num_feat, num_out_ch * upscale * upscale, 3, 1, 1))
        # 上采样
        self.upsampler = nn.PixelShuffle(upscale)

    @staticmethod
    def _make_activation(act_type, num_feat):
        if act_type == 'relu':
            return nn.ReLU(inplace=True)
        elif act_type == 'prelu':
            return nn.PReLU(num_parameters=num_feat)
        elif act_type == 'leakyrelu':
            return nn.LeakyReLU(negative_slope=0.1, inplace=True)
        else:
            raise ValueError(f"不支持的激活函数类型: {act_type}")

    def forward(self, x):
        out = x
        for i in range(0, len(self.body)):
            out = self.body[i](out)

        out = self.upsampler(out)
        # 加上最近邻上采样的输入，使网络学习残差
        base = F.interpolate(x, scale_factor=self.upscale, mode='nearest')
        out += base
        return out
