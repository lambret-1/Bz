iOS 视频增强工作台 · 开发大纲

项目定位：端侧视频增强工具，专注「导入 → 编辑 → 增强 → 导出」闭环。
最低系统：iOS 16.0
开发环境：GitHub Actions macOS Runner（无需本地 Mac）
分发方式：未签名 IPA，通过 AltStore / SideStore / TrollStore 侧载
核心原则：无设备分级，参数由用户手动选择。不写死 A16/A14/A13 判断，不自动限制分辨率或倍数，所有选项开放给用户，由用户自行权衡画质与耗时。

1. 功能矩阵总览

类别 功能 技术方案 算力消耗 互斥关系
流畅度 补帧 2x / 4x RIFE Lite (Core ML) 高 与超分互斥
分辨率 超分 2x PiperSR (Core ML) 中 与补帧互斥
分辨率 超分 4x Real-ESRGAN x4v3 (Core ML) 高 与补帧互斥
清晰度 自适应锐化 Metal Shader 极低 可叠加
清晰度 对比度/色彩增强 Metal Shader 极低 可叠加
清晰度 双边滤波降噪 Metal Shader 低 可叠加
清晰度 Lanczos 缩放 Metal Shader 低 内部使用
音频 音频修复/透传 AVAssetReader/Writer + Composition 极低 可叠加
编辑 分切/复制/删除/排序 数据模型 + AVMutableComposition 无 基础操作
导出 HEVC 编码 + 动态码率 AVAssetWriter 低 全局生效

2. 核心数据模型

2.1 Project

```swift
struct Project: Identifiable, Codable {
    let id: UUID
    var name: String
    var sourceVideoPath: String        // 原始视频（永不修改）
    var segments: [VideoSegment]       // 时间线片段
    var enhancementTasks: [EnhancementTask]
    var outputPath: String?
    var status: ProjectStatus
    var originalInfo: VideoInfo
    var exportSettings: ExportSettings
    var createdAt: Date
    var updatedAt: Date
}
```

2.2 VideoSegment

```swift
struct VideoSegment: Identifiable, Codable {
    let id: UUID
    var sourceStart: TimeInterval   // 源视频起点
    var sourceEnd: TimeInterval     // 源视频终点
    var isMuted: Bool
    var duration: TimeInterval { sourceEnd - sourceStart }
}
```

2.3 EnhancementTask

```swift
enum EnhancementTask: String, Codable, CaseIterable {
    // 互斥组
    case interpolate2x, interpolate4x
    case superResPiper, superResESRGAN
    // 可叠加组
    case denoise, sharpen, contrastBoost, saturationBoost, audioFix
}

// 互斥校验
func validate(tasks: [EnhancementTask]) -> Bool {
    let interSet: Set = [.interpolate2x, .interpolate4x]
    let srSet: Set = [.superResPiper, .superResESRGAN]
    let hasInter = !Set(tasks).intersection(interSet).isEmpty
    let hasSR = !Set(tasks).intersection(srSet).isEmpty
    return !(hasInter && hasSR)
}
```

2.4 ExportSettings

```swift
struct ExportSettings: Codable {
    var codec: VideoCodec = .hevc
    var bitrateMode: BitrateMode = .auto
    var container: ContainerType = .auto
    var audioStrategy: AudioStrategy = .passthrough
}

enum VideoCodec: String, Codable { case h264, hevc }
enum BitrateMode: String, Codable { case auto, high, balanced, small }
enum ContainerType: String, Codable { case auto, mov, mp4 }
enum AudioStrategy: String, Codable { case passthrough, aacTranscode }
```

3. 引擎接口设计

3.1 补帧引擎

```swift
protocol FrameInterpolationEngine {
    func interpolate(frame0: CVPixelBuffer, frame1: CVPixelBuffer, t: Float) -> Result<CVPixelBuffer, InterpolationError>
    func reduceInputSize() // 仅内存警告时临时降级，不依赖机型
}

final class RIFEInterpolationEngine: FrameInterpolationEngine {
    private var inputSize: Int = 512
    // ...
}
```

3.2 超分引擎

```swift
protocol SuperResolutionEngine {
    var scale: Int { get }
    var inputSize: CGSize { get }
    func upscale(_ pixelBuffer: CVPixelBuffer) -> Result<CVPixelBuffer, SuperResolutionError>
}

final class PiperSREngine: SuperResolutionEngine {
    let scale = 2
    let inputSize = CGSize(width: 640, height: 360)
    // ...
}

final class RealESRGANEngine: SuperResolutionEngine {
    let scale = 4
    let inputSize = CGSize(width: 128, height: 128)
    // ...
}
```

超分引擎选择逻辑（无设备分级）：

```swift
func selectSuperResolutionEngine(inputWidth: Int) -> SuperResolutionEngine? {
    if inputWidth <= 480 { return RealESRGANEngine() }
    else if inputWidth <= 720 { return PiperSREngine() }
    else { return nil } // 1080p 及以上不启用超分
}
```

3.3 清晰度增强引擎

```swift
final class EnhancementEngine {
    struct Params {
        var denoiseStrength: Float = 0.0
        var sharpenStrength: Float = 0.4
        var contrast: Float = 1.0
        var saturation: Float = 1.0
    }
    func apply(_ pixelBuffer: CVPixelBuffer, params: Params) -> Result<CVPixelBuffer, EnhancementError>
}
```

3.4 时间线合成器

```swift
final class TimelineCompositionBuilder {
    static func build(sourceURL: URL, segments: [VideoSegment]) async throws -> AVMutableComposition
    static func buildVideoOnly(sourceURL: URL, segments: [VideoSegment]) async throws -> AVMutableComposition
    static func buildAudioOnly(sourceURL: URL, segments: [VideoSegment]) async throws -> AVMutableComposition
}
```

3.5 总调度器

```swift
final class ProjectPipeline {
    func process(
        project: Project,
        progress: @escaping (Double, ProcessingStage) -> Void,
        completion: @escaping (Result<URL, Error>) -> Void
    )
    func cancel()
}

enum ProcessingStage: String {
    case idle, composing, denoising, enhancing, postProcessing, audioFix, encoding, finished
}
```

4. 处理管线编排

4.1 执行顺序（固定）

```
1. 剪辑合成：segments → AVMutableComposition → 临时视频
2. 降噪：双边滤波（可选）
3. 增强：补帧 或 超分（互斥，二选一）
4. 后处理：Lanczos 缩放 → 锐化 → 对比度/色彩（可叠加）
5. 音频：独立 Reader 读取原始音频 + 修复/透传
6. 编码：HEVC + 动态码率 + 动态容器 → 输出
```

4.2 动态码率计算

```swift
func calculateBitrate(original: Int, multiplier: Int, inputWidth: Int, outputWidth: Int) -> Int {
    let multiplierFactor: Double = multiplier == 4 ? 3.0 : (multiplier == 2 ? 1.8 : 1.0)
    let resolutionFactor: Double = outputWidth > inputWidth ? 1.5 : 1.0
    let target = Int(Double(original) * multiplierFactor * resolutionFactor)
    return min(max(target, 2_000_000), 25_000_000) // 2M–25M
}
```

4.3 动态容器与音频策略

```swift
func selectContainerAndAudioStrategy(inputAudioCodec: String?) -> (ContainerType, AudioStrategy) {
    let codec = inputAudioCodec?.lowercased() ?? ""
    if codec == "lpcm" || codec == "alac" {
        return (.mov, .passthrough)     // PCM/ALAC 只能 MOV 透传
    } else if codec == "aac" {
        return (.mp4, .passthrough)     // AAC 可以 MP4 透传
    } else {
        return (.mp4, .aacTranscode)    // 其他重编码为 AAC
    }
}
```

4.4 运行时保护（无设备分级）

```swift
final class ThermalMonitor {
    var shouldDegrade: Bool {
        ProcessInfo.processInfo.thermalState == .serious ||
        ProcessInfo.processInfo.thermalState == .critical
    }
}
```

降级策略：

· 过热时：仅提示用户“设备温度较高，建议降低设置或暂停处理”。
· 不自动更改用户选择的参数，由用户自行决定继续或退出。
· 内存警告：reduceInputSize() 临时降低模型输入尺寸，处理结束后恢复。

5. Metal Shader 清单

Shader 用途 ThreadGroup
bgra_to_nchw BGRA → NCHW FP16 16×16
nchw_to_bgra NCHW FP16 → BGRA 16×16
sigmoid_mask 掩码 Sigmoid 256×1
warp_frame 光流 Warp 16×16
blend_frames 掩码混合 16×16
adaptive_sharpen 自适应锐化 16×16
contrast_boost 对比度增强 16×16
saturation_boost 色彩增强 16×16
bilateral_denoise 双边滤波降噪 16×16
lanczos_resize Lanczos 缩放 16×16

6. UI 页面细化

6.1 页面清单

页面 功能
首页 HomeView 项目列表 + 新建
项目详情 ProjectDetailView 预览 + 时间线 + 增强参数
时间线 TimelineView 片段卡片 + 播放头 + 编辑工具栏
处理中 ProcessingView 统一进度环 + 任务清单
结果 ResultView 左右对比播放 + 保存/分享
导出设置 ExportSettingsView 编码/码率/容器
设置 SettingsView 默认参数

6.2 首页元素

```
NavigationStack
├── 标题「我的项目」
├── 右上角 [+] 新建
├── 项目网格（LazyVGrid 2列）
│   └── ProjectCard
│       ├── 缩略图 16:9
│       ├── 项目名
│       ├── 时长
│       ├── 状态标签
│       └── 已应用任务图标
└── 空状态：「导入视频开始」
```

6.3 项目详情页元素

```
ScrollView
├── 视频预览区（AVPlayer）
├── 时间线区域
│   ├── 播放头 + 时间显示
│   ├── 片段卡片列表（横向滚动，点击选中，长按排序）
│   └── 编辑工具栏 [✂️分切] [📋复制] [🗑️删除] [↩️撤销]
├── 增强任务区域
│   ├── 互斥组：补帧（2x/4x）/ 超分（PiperSR/ESRGAN）
│   ├── 清晰度增强折叠区
│   │   ├── 降噪 Toggle + Slider
│   │   ├── 锐化 Toggle + Slider
│   │   ├── 对比度 Toggle + Slider
│   │   └── 色彩 Toggle + Slider
│   └── 音频修复 Toggle
├── 导出设置入口
└── 底部固定 [开始处理并导出]
```

6.4 处理中页元素（修复进度条冲突）

```
VStack
├── 顶部：取消按钮
├── 进度环（唯一，内部包含百分比与帧数）
├── 任务清单（纵向列表）
│   ├── ✅ 剪辑合成
│   ├── 🔄 超分增强（45%）
│   ├── ⏳ 清晰度优化（等待）
│   └── ⏳ 音频修复（等待）
├── 状态文案 + 预计剩余时间
└── 底部提示（保持前台）
```

6.5 结果页元素

```
ScrollView
├── 左右分屏对比播放器
├── 处理信息卡片（原始 vs 输出参数）
├── [保存到相册] [分享] [再次处理]
└── 处理历史
```

7. 开发阶段与任务拆解

第 1 周：基础设施与数据模型

□ 创建 feature/editor 分支
□ 定义 Project / VideoSegment / EnhancementTask / ExportSettings
□ 实现项目持久化（JSON + 文件夹）
□ 单元测试：模型编解码、互斥校验
□ CI 验证通过

第 2 周：编辑操作与时间线合成

□ splitSegment / duplicateSegment / deleteSegment / moveSegment
□ 单元测试：编辑操作边界
□ TimelineCompositionBuilder 实现
□ 预览播放验证

第 3 周：时间线 UI

□ TimelineView 片段卡片
□ EditToolbar 分切/复制/删除
□ 播放头交互
□ 拖动排序动画

第 4 周：项目管理 UI

□ HomeView 项目列表
□ ProjectCard 组件
□ 新建项目流程
□ 项目删除/重命名

第 5 周：管线整合

□ ProjectPipeline 总调度
□ 接入 RIFE 补帧
□ 接入音频修复
□ 处理进度页改造

第 6 周：超分接入

□ 接入 PiperSR
□ 接入 Real-ESRGAN
□ 超分引擎路由逻辑
□ 互斥 UI 提示

第 7 周：清晰度增强

□ Metal Shader：锐化/降噪/对比度/Lanczos
□ EnhancementEngine 封装
□ 参数 Slider UI
□ 效果验证

第 8 周：导出优化

□ HEVC 编码
□ 动态码率计算
□ 动态容器选择
□ 导出设置页

第 9 周：结果与体验

□ 结果页对比播放
□ 保存/分享
□ 撤销/重做
□ 草稿恢复

第 10 周：测试与发布

□ 多设备测试（仅测功能，不写机型判断）
□ 边界测试
□ 性能测试（记录耗时，不自动限制）
□ Release 打包 + 侧载教程

8. 测试用例细化

编辑操作

用例 操作 预期
分切 3.5s 处切 10s 视频 3.5s + 6.5s 两段
分切边界 0.01s 处切 拒绝，提示太短
复制 复制中间片段 数组 +1，内容一致
删除 删除唯一片段 拒绝，至少保留 1 个
排序 拖动片段 2 到位置 0 顺序改变
撤销 编辑后撤销 恢复上一次状态

增强任务

用例 输入 预期
补帧 2x 30fps 60fps，音画同步
补帧 4x 30fps 120fps
超分 PiperSR 720p 1440p → 缩放 1080p
超分 ESRGAN 480p 1920p → 缩放 1080p
互斥校验 同时选补帧+超分 拒绝，提示
锐化 strength=0.4 边缘锐利，无光晕
降噪 夜景视频 噪点减少，细节保留

编码与导出

用例 输入 预期
HEVC 编码 1080p 30fps 文件比 H.264 小 30%
动态码率 2x 补帧 码率 ≈ 原码率 × 1.8
码率上限 4K 输入 码率 ≤ 25M
音频透传 MOV + PCM 输出 MOV，有声
音频转码 MP4 + AAC 输出 MP4，有声
无音频视频 无音轨 正常输出，无崩溃

异常与稳定性

用例 操作 预期
长视频 5 分钟 1080p 内存 < 300MB
过热 连续处理 5 分钟 仅提示，不自动改参数
取消 50% 时取消 临时文件清理
存储不足 磁盘满 提示，不崩溃
不支持格式 MKV 输入 提示不支持

9. 工程结构策略

```
FrameInterpolation/
├── App/
├── DesignSystem/
├── Features/
│   ├── Home/, Project/, Processing/, Result/, Settings/, Import/
├── Core/
│   ├── Pipeline/      (ProjectPipeline, VideoPipeline, BoundedQueue, TimelineBuilder)
│   ├── Engines/       (RIFE, PiperSR, RealESRGAN, EnhancementEngine)
│   ├── Metal/         (MetalContext, MetalComputeHelper, Shaders.metal)
│   ├── Import/        (MediaImporter, PermissionManager)
│   ├── System/        (ThermalMonitor, MemoryWatcher, PipelineMetrics, HapticManager)
│   └── Config/        (AppSettings, AppError)
├── Models/            (Project, VideoSegment, EnhancementTask, ExportSettings, VideoInfo)
├── State/             (AppState, ProjectStore)
├── Resources/         (Assets, Info.plist, RIFE_Lite, PiperSR, RealESRGAN)
└── Tests/
```




10. 关键约束汇总

1. 无设备分级，所有参数由用户手动选择。
2. 补帧与超分互斥，UI 层禁止同时勾选。
3. 原始文件永不修改，编辑只改 segments 数组。
4. 至少保留一个片段。
5. 清晰度增强顺序固定：降噪 → 超分/补帧 → 缩放 → 锐化 → 对比度。
6. 编码统一 HEVC + 动态码率，上限 25Mbps。
7. 音频策略动态选择：PCM → MOV，AAC → MP4。
8. 长视频分段处理：30 秒一段，单 Writer 连续写入。
9. 热降级仅提示，不自动改参数。
10. 不做多轨道，只做单轨增强。
11. 不上架 App Store，侧载分发。

---

## 版本记录

### v0.3.0 — UI 细化全面落地

按照「资料/1.UI 细化」规格完成全部 UI 页面重构：

- **设计系统**：DesignTokens 精确配色（深色/浅色双模式）、字体令牌、间距圆角统一
- **组件库**：PrimaryButton（按下态 scale+opacity）、CardView（浅色阴影）、SegmentedPicker、TaskTag、ToastView、RingProgressView、EmptyStateView、CollapsibleSectionHeader、InfoRow、ToolbarActionButton
- **首页**：项目网格（2列 LazyVGrid）+ ProjectCard（缩略图/时长/任务标签/状态）+ 空状态 + 长按菜单（重命名/复制/删除）
- **项目详情页**：视频预览（AVPlayer 封装+自定义控制条）+ 时间线（播放头拖拽+片段卡片横向滚动）+ 编辑工具栏（分切/复制/删除/撤销）+ 增强任务（补帧/超分互斥单选+清晰度折叠区+音频修复）+ 导出设置入口 + 底部固定开始按钮
- **处理中页**：唯一进度环 + 任务清单（完成/进行中/等待三态）+ 热状态提示 + 取消确认
- **结果页**：左右对比播放器（同步播放）+ 处理信息卡片 + 保存/分享/再次处理
- **导出设置页**：编码/码率/容器/音频 Picker + 预计输出实时计算
- **设置页**：通用（触觉反馈/屏幕常亮）+ 默认导出设置 + 存储（缓存清理）+ 关于
- **状态管理**：项目制持久化、片段编辑撤销栈、增强配置互斥校验
- **导航**：全部独立 fullScreenCover + NavigationStack，左上角返回按钮 + 边缘左滑手势

所有页面适配深色/浅色模式、动态字体、VoiceOver，按钮最小点击区域 44pt。