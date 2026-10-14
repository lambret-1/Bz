#include <metal_stdlib>
using namespace metal;

// MARK: - BGRA → NCHW Float16 预处理
/// 将 BGRA 格式的纹理转换为 NCHW 布局的 Float16 缓冲区，归一化到 [0, 1]
/// 输入：src 纹理（BGRA，0-255）
/// 输出：dst 缓冲区（NCHW Float16，R/G/B 三个平面，0-1）
kernel void bgra_to_nchw(
    texture2d<float, access::read> src [[texture(0)]],
    device half *dst [[buffer(0)]],
    constant uint &width [[buffer(1)]],
    constant uint &height [[buffer(2)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= width || gid.y >= height) return;

    float4 color = src.read(gid);
    uint pixelIndex = gid.y * width + gid.x;
    uint channelStride = width * height;

    // NCHW 布局：先 R 平面，再 G 平面，再 B 平面
    dst[0 * channelStride + pixelIndex] = half(color.r);
    dst[1 * channelStride + pixelIndex] = half(color.g);
    dst[2 * channelStride + pixelIndex] = half(color.b);
}

// MARK: - Sigmoid 激活
/// 对掩码缓冲区执行逐元素 Sigmoid 激活
kernel void sigmoid_mask(
    device half *mask [[buffer(0)]],
    constant uint &count [[buffer(1)]],
    uint gid [[thread_position_in_grid]]
) {
    if (gid >= count) return;
    float v = float(mask[gid]);
    mask[gid] = half(1.0 / (1.0 + exp(-v)));
}

// MARK: - 光流 Warp
/// 根据光流对源帧进行双线性采样，生成 Warp 后的帧
/// 输入：src 纹理（待 warp 的帧），flow 缓冲区（NCHW Float16，2 通道：x/y 方向光流）
/// 输出：dst 纹理（warp 后的帧）
kernel void warp_frame(
    texture2d<float, access::sample> src [[texture(0)]],
    texture2d<float, access::write> dst [[texture(1)]],
    device half *flow [[buffer(0)]],
    constant uint &width [[buffer(1)]],
    constant uint &height [[buffer(2)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= width || gid.y >= height) return;

    uint pixelIndex = gid.y * width + gid.x;
    uint channelStride = width * height;

    // 读取光流（x, y 两个通道）
    float2 flowValue = float2(
        float(flow[0 * channelStride + pixelIndex]),
        float(flow[1 * channelStride + pixelIndex])
    );

    // 采样坐标 = 当前坐标 + 光流偏移
    float2 sampleCoord = float2(gid) + flowValue;

    constexpr sampler s(coord::pixel, address::clamp_to_edge, filter::linear);
    float4 color = src.sample(s, sampleCoord);
    dst.write(color, gid);
}

// MARK: - 掩码混合
/// 按掩码加权混合两帧：output = frame0 * (1 - mask) + frame1 * mask
kernel void blend_frames(
    texture2d<float, access::read> frame0 [[texture(0)]],
    texture2d<float, access::read> frame1 [[texture(1)]],
    texture2d<float, access::write> output [[texture(2)]],
    device half *mask [[buffer(0)]],
    constant uint &width [[buffer(1)]],
    constant uint &height [[buffer(2)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= width || gid.y >= height) return;

    uint pixelIndex = gid.y * width + gid.x;
    float m = float(mask[pixelIndex]);

    float4 c0 = frame0.read(gid);
    float4 c1 = frame1.read(gid);

    output.write(mix(c0, c1, m), gid);
}
