# iOS 视频补帧 App 开发大纲

## 1. 项目概述

### 1.1 项目目标
开发一款 iOS 应用，支持用户导入本地视频，在设备端快速完成 AI 补帧（如 30fps → 60fps），输出流畅的高帧率视频。
- **最低系统版本**：iOS 16.0
- **核心特性**：完全端侧运行、无需网络、保护隐私
- **开发环境**：无 Mac 电脑，全程使用 GitHub Actions 云端 macOS Runner 完成编译与分发
- **分发方式**：不上架 App Store，仅通过 AltStore / SideStore / TrollStore 等工具侧载到个人设备

### 1.2 核心约束
- 无本地 Mac，所有 Xcode 构建均在 GitHub Actions 的 macOS Runner 上执行
- 构建产物为未签名 IPA，通过侧载工具安装到 iPhone
- 本项目为个人开发/测试用途，不提交 App Store 审核

### 1.3 核心功能
- 导入视频（相册 / 文件 App）
- 选择补帧倍数（2x / 4x）
- 选择输出分辨率与帧率
- 实时预览处理进度
- 导出并保存到相册
- 支持后台处理（可选）


## 2. 技术选型与可行性

### 2.1 核心技术栈
| 层级 | 技术 | 用途 |
| :--- | :--- | :--- |
| 视频解码 | AVFoundation (`AVAssetReader`) | 逐帧读取视频 |
| AI 推理 | Core ML + RIFE Lite | 光流估计与插帧 |
| 图像处理 | Metal Shader | 预处理、Warp、Blend |
| 视频编码 | AVFoundation (`AVAssetWriter`) | 重新封装输出视频 |
| 并发 | GCD + 有界队列 | 异步流水线 |
| UI | SwiftUI | 界面开发 |
| 构建 | GitHub Actions + XcodeGen | 云端编译与打包 |

### 2.2 为什么选择 Core ML + RIFE Lite？
- iOS 16 无法使用系统原生 ML 插帧
- RIFE Lite 在移动端平衡了速度与质量
- 转换为 Float16 Core ML 模型后可调用 ANE，能效比高
- 社区有成熟转换方案与参考实现

### 2.3 性能预期
| 设备芯片 | 建议分辨率 | 补帧倍数 | 预期速度 |
| :--- | :--- | :--- | :--- |
| A16 及以上 | 1080p | 2x | 近实时 |
| A14 / A15 | 720p | 2x | 可接受 |
| A13 及以下 | 480p | 2x | 较慢，需降级 |


## 3. 系统架构与核心流程

### 3.1 总体架构图
```

用户导入视频
↓
[AVAssetReader] 解码 → CMSampleBuffer → CVPixelBuffer
↓
[解码队列] → [推理队列] → [编码队列]
↓
[Metal Shader] 预处理：BGRA → NCHW Float16
↓
[Core ML] RIFE Lite 推理 → 输出光流 + 掩码
↓
[Metal Shader] 后处理：Sigmoid → Warp → Blend → 生成中间帧
↓
[AVAssetWriter] 重新计算 PTS → 编码 → 输出视频
↓
保存到相册

```

### 3.2 核心模块划分
1. **视频读取模块**：读取视频元数据、解码、音频轨道分离
2. **预处理模块（Metal）**：BGRA → NCHW Float16 格式转换、尺寸缩放
3. **AI 推理模块（Core ML）**：RIFE Lite 推理，输出光流与掩码
4. **后处理模块（Metal）**：Sigmoid、Warp、Blend 生成中间帧
5. **视频编码模块**：重新计算 PTS，写入视频，音频透传
6. **异步流水线调度**：解码、推理、编码三队列并行，带背压机制
7. **任务调度与 UI**：进度回调、取消操作、错误处理、设备降级


## 4. 云端开发环境架构

### 4.1 整体架构
- 本地开发环境：Windows / Linux，仅需 Git 与代码编辑器
- 云端构建：GitHub Actions macOS Runner（公共仓库免费）
- 构建工具：XcodeGen 生成工程，xcodebuild 打包
- 分发方式：下载未签名 IPA，通过 AltStore / SideStore / TrollStore 侧载

### 4.2 工具选型
| 工具 | 用途 | 费用 |
| :--- | :--- | :--- |
| XcodeGen | 从 project.yml 生成 Xcode 工程 | 免费 |
| ios-builder (可选) | 简化远程构建与下载 IPA | 免费 |
| AltStore / SideStore | 未签名 IPA 侧载 | 免费 |
| TrollStore | 永久安装（特定 iOS 版本） | 免费 |


## 5. 开发阶段规划（细化版）

### 5.1 里程碑总览
| 阶段 | 目标 | 预计周期 | 关键里程碑 |
| :--- | :--- | :--- | :--- |
| 阶段 0 | 云端构建与侧载闭环 | 1 周 | 空白 App 可自动构建并侧载 |
| 阶段 1 | RIFE Lite 模型转换与推理验证 | 1–2 周 | Core ML 模型在 ANE 上跑通 |
| 阶段 2 | Metal 预处理/后处理与静态图插帧 | 2 周 | 两张图片生成中间帧 |
| 阶段 3 | 视频流处理管线 | 2–3 周 | 端到端输出高帧率视频 |
| 阶段 4 | 性能优化与设备适配 | 2 周 | A16 1080p 近实时补帧 |
| 阶段 5 | UI 与用户体验 | 1–2 周 | 完整可用 App |
| 阶段 6 | 真机测试与侧载分发 | 1 周 | 发布未签名 IPA Release |

### 5.2 阶段 0：项目启动与云端构建基础设施（1 周）
**目标**：建立无需 Mac 的完整开发闭环，确保代码推送后能自动产出可侧载的 IPA。

**任务清单**：
- [ ] 创建 GitHub 仓库，初始化 Xcode 工程（使用 XcodeGen）
- [ ] 配置 Bundle ID、最低 iOS 16、权限声明
- [ ] 编写 `.github/workflows/ios-build.yml`：
  - Checkout 代码
  - 安装 XcodeGen 并生成工程
  - 解析 Swift Package 依赖
  - `xcodebuild archive` 禁用签名
  - 导出未签名 IPA
  - 上传 Artifact
- [ ] 配置 SPM 与 DerivedData 缓存
- [ ] 配置 tag 触发 GitHub Release，自动上传 IPA
- [ ] 本地安装 AltStore / SideStore，验证空白 App 可侧载启动
- [ ] 建立真机日志查看方式

**验收标准**：
- `git push` 后 GitHub Actions 自动构建成功
- 产出未签名 IPA，可下载并侧载到 iPhone
- 空白 App 可正常启动，无崩溃
- 单次构建时间控制在 20 分钟以内

**交付物**：GitHub 仓库、`ios-build.yml`、空白 App IPA、侧载操作说明。

### 5.3 阶段 1：RIFE Lite 模型转换与 Core ML 推理验证（1–2 周）
**目标**：获得可在 ANE 上运行的 RIFE Lite Core ML 模型，并验证精度与速度。

**前置依赖**：需要一个 macOS 环境执行一次性转换（可借用 Mac、云 Mac，或使用 GitHub Actions macOS Runner 跑转换脚本）。

**任务清单**：
- [ ] 选定 RIFE Lite 模型版本
- [ ] 编写 PyTorch → TorchScript / ONNX → Core ML 转换脚本
- [ ] 使用 `coremltools` 转换，指定 `mlprogram`、`FLOAT16`
- [ ] 验证模型输入输出维度
- [ ] 编写最小 Swift 测试：加载 `.mlpackage`，设置 `computeUnits = .all`
- [ ] 在不同分辨率下测量 ANE 推理耗时
- [ ] 将 `.mlpackage` 提交到仓库或使用 Git LFS 管理

**验收标准**：
- Core ML 模型可正常加载，输出维度正确
- 推理结果与 PyTorch 参考结果误差在可接受范围
- A16 设备上 1080p 单次推理 < 50ms
- ANE 被实际调用，而非回退 CPU

**交付物**：模型转换脚本、`.mlpackage` 文件、推理测试代码、性能测试报告。

### 5.4 阶段 2：Metal 预处理 / 后处理与静态图插帧闭环（2 周）
**目标**：实现 GPU 上的格式转换与插帧合成，用静态图片验证中间帧生成效果。

**任务清单**：
- [ ] 编写 Metal Compute Shader：
  - `bgra_to_nchw`：`CVPixelBuffer` BGRA → Float16 NCHW
  - `sigmoid_mask`：对掩码执行 Sigmoid
  - `warp_frame`：根据光流对前后帧做双线性采样
  - `blend_frames`：按掩码加权混合，生成中间帧
- [ ] 封装 `FrameInterpolator` 类
- [ ] 处理模型输入尺寸与视频尺寸不一致的缩放/裁剪策略
- [ ] 用两张静态图片生成中间帧，保存 PNG 并肉眼验证
- [ ] 编写性能测试：预处理、推理、后处理各阶段耗时

**验收标准**：
- 静态图片可生成视觉合理的中间帧，无明显伪影
- A16 上 1080p 单帧插帧总耗时 < 100ms
- 无内存泄漏，连续处理 100 张图片稳定

**交付物**：Metal Shader 源码、`FrameInterpolator` 模块、静态图测试用例、性能报告。

### 5.5 阶段 3：视频流处理管线（2–3 周）
**目标**：打通「解码 → 补帧 → 编码」完整链路，输出可播放的高帧率视频。

**任务清单**：
- [ ] 读取视频元数据：分辨率、帧率、时长、旋转、音频轨道
- [ ] 使用 `AVAssetReader` 逐帧解码，输出 `CVPixelBuffer`
- [ ] 维护前后帧队列，调用 `FrameInterpolator` 生成中间帧
- [ ] 使用 `AVAssetWriter` + `AVAssetWriterInputPixelBufferAdaptor` 编码
- [ ] 重新计算 PTS：原 30fps → 60fps，每帧时间间隔减半
- [ ] 音频轨道透传，保持原始时间戳，确保音画同步
- [ ] 使用 `CVPixelBufferPool` 复用缓冲区，`autoreleasepool` 包裹每帧处理
- [ ] 实现进度回调、预计剩余时间、取消机制
- [ ] 输出到相册或文件 App

**验收标准**：
- 导入 10 秒 30fps 视频，输出 60fps 视频，可正常播放
- 音画同步，无明显偏移
- 1080p 输入下内存峰值 < 500MB
- 取消处理不崩溃，临时文件被清理

**交付物**：`VideoPipeline` 模块、导出功能、测试视频、PTS 计算工具类。

### 5.6 阶段 4：性能优化与设备适配（2 周）
**目标**：在不同芯片设备上稳定运行，控制发热与内存，提升处理速度。

**任务清单**：
- [ ] 构建异步流水线：
  - 解码队列、推理队列、编码队列并行
  - 使用有界队列（`BoundedQueue`）实现背压
- [ ] 设备分级策略：
  - A16 及以上：1080p / 2x
  - A14–A15：720p / 2x
  - A13 及以下：480p / 2x 或快速模式
- [ ] 热状态监控：`ProcessInfo.thermalState`，过热自动降级
- [ ] 内存优化：限制在途帧数、复用纹理与缓冲区
- [ ] 后台处理支持：`beginBackgroundTask`，处理时屏幕常亮
- [ ] 实现「快速模式」：Metal 简单帧混合，不调用 AI 推理
- [ ] 使用 `os_signpost` 打点，真机分析各阶段耗时

**验收标准**：
- A16 上 1080p 2x 补帧速度 ≥ 视频时长的 0.8 倍（近实时）
- A14 上 720p 2x 补帧速度 ≥ 视频时长的 0.5 倍
- 连续处理 5 分钟不过热降频崩溃
- 快速模式可正常输出，速度 ≥ 2 倍实时

**交付物**：性能优化代码、设备分级配置、热监控与降级逻辑、性能测试报告。

### 5.7 阶段 5：UI 与用户体验（1–2 周）
**目标**：提供完整、易用的 App 界面，覆盖导入、设置、处理、导出全流程。

**任务清单**：
- [ ] SwiftUI 页面：
  - 首页：导入视频、最近项目
  - 设置页：补帧倍数、输出分辨率、快速模式开关
  - 处理页：视频预览、进度条、剩余时间、取消按钮
  - 结果页：预览、保存到相册、分享
- [ ] 权限处理：相册读写、文件访问
- [ ] 错误提示：解码失败、内存不足、不支持格式
- [ ] 状态管理：`ObservableObject` / `@Observable`
- [ ] 中英文本地化（可选）
- [ ] App 图标与启动屏

**验收标准**：
- 完整流程：导入 → 设置 → 处理 → 保存，无崩溃
- 进度实时更新，可取消
- UI 适配 iPhone 各尺寸，无布局错乱
- 错误提示清晰，用户可理解

**交付物**：完整 App 界面、图标资源、本地化文件、交互说明。

### 5.8 阶段 6：真机测试与侧载分发（1 周）
**目标**：在多设备上验证稳定性，发布可侧载的未签名 IPA。

**任务清单**：
- [ ] 多设备测试：A16 / A15 / A14 / A13，iOS 16 / 17 / 18
- [ ] 边界测试：4K 视频、慢动作、HDR、旋转视频、无音频视频
- [ ] 长时间稳定性测试：连续处理多个视频
- [ ] 修复测试中发现的 bug，优化体验
- [ ] 编写 README、侧载教程、使用说明
- [ ] 打 tag，通过 GitHub Release 上传未签名 IPA
- [ ] 制作演示视频或 GIF（可选）

**验收标准**：
- 目标设备均可安装并运行
- 核心功能稳定，无严重崩溃
- GitHub Release 提供 IPA 与安装说明
- 侧载教程清晰，新用户可按步骤完成安装

**交付物**：最终未签名 IPA、README、侧载教程、演示素材。


## 6. UI 界面详细设计（规格概要）

### 6.1 设计系统
- **颜色**：深色模式为主，强调色 `#0A84FF`，背景 `#000000`，卡片 `#1C1C1E`
- **字体**：SF Pro，使用语义化字体（`.title2` / `.headline` / `.body` / `.caption`）
- **间距**：4 / 8 / 16 / 24 / 32 pt
- **圆角**：8 / 12 / 16 / 24 pt
- **图标**：SF Symbols，线宽 regular

### 6.2 页面结构
1. **首页**：导入卡片 + 最近记录列表
2. **参数设置页**：视频预览卡片、补帧倍数、输出分辨率、快速模式、预估信息、开始按钮
3. **处理中页**：环形进度条、状态文案、剩余时间、取消按钮、防息屏提示
4. **结果预览页**：视频播放器、对比信息、保存/分享按钮、再次处理
5. **设置页**：通用、性能、存储、关于

### 6.3 通用组件
- `PrimaryButton`：高度 52pt，圆角 12pt，强调色背景
- `CardView`：背景 `bgSecondary`，圆角 16pt
- `SegmentedPicker`：分段控件，高度 36pt
- `RingProgressView`：环形进度，160pt 外径
- `ToastView`：顶部滑入，2 秒后消失
- `EmptyStateView`：空状态插画 + 文案

### 6.4 无障碍与本地化
- VoiceOver 标签、动态字体、深色模式适配
- 中英文本地化，使用 `Localizable.strings`


## 7. CI/CD 工作流设计

### 7.1 主工作流 `ios-build.yml`
- **触发**：push 到 main、打 tag `v*`、手动触发
- **步骤**：
  1. Checkout 代码
  2. 安装 XcodeGen
  3. 注入版本号（从 tag 或 project.yml）
  4. 缓存 Swift Packages
  5. 生成 Xcode 工程
  6. `xcodebuild archive` 禁用签名
  7. 导出未签名 IPA
  8. 上传 Artifact
  9. 若为 tag 或手动发布，创建 GitHub Release 并上传 IPA

### 7.2 版本管理
- `MARKETING_VERSION`：语义化版本，来自 Git tag
- `CURRENT_PROJECT_VERSION`：GitHub Actions run number
- Tag 格式：`v1.0.0`

### 7.3 发布流程
- 日常迭代：push 到 main，仅构建并保留 Artifact
- 发布版本：打 tag `v1.0.0`，自动创建 Release 并上传 IPA
- 手动触发：可选择是否发布 Release


## 8. 核心实现要点

### 8.1 模型转换
- 使用 `coremltools` 转换 RIFE Lite
- 指定 `mlprogram` 格式，`compute_precision=FLOAT16`
- 通过 GitHub Actions macOS Runner 一次性完成转换

### 8.2 FrameInterpolator
- Metal 预处理：BGRA → NCHW Float16
- Core ML 推理：`computeUnits = .all`，调用 ANE
- Metal 后处理：Sigmoid → Warp → Blend → 输出 BGRA
- 支持 `t` 参数，实现 2x / 4x 补帧

### 8.3 VideoPipeline
- 异步流水线：解码、推理、编码三队列并行
- 有界队列（`BoundedQueue`）实现背压，控制内存
- 音频独立线程透传，保持音画同步
- 4x 补帧采用递归策略（RIFE）
- 热降级：`ProcessInfo.thermalState` 触发降分辨率或跳过插帧
- 错误恢复：帧级复制补位、段级跳过插帧、任务级空转降级
- 长视频分段处理：每段 30 秒，单 Writer 连续写入
- 性能埋点：`os_signpost` 记录各阶段耗时

### 8.4 设备能力分级
- 根据芯片型号推荐分辨率与倍数
- 运行时检测热状态，动态调整模型输入尺寸


## 9. 交付物清单

- [ ] GitHub 仓库（包含 `.github/workflows/ios-build.yml`）
- [ ] Core ML `.mlpackage` 模型文件
- [ ] Metal Shader 源码
- [ ] Swift 核心处理管线代码
- [ ] SwiftUI 界面代码
- [ ] 未签名 IPA 构建产物（用于侧载）
- [ ] README、侧载教程、使用说明


## 10. 参考资源

- [GitHub Actions 免费 macOS Runner 说明](https://docs.github.com/en/actions/using-github-hosted-runners/about-github-hosted-runners)
- [Core ML 官方文档](https://developer.apple.com/documentation/coreml)
- [RIFE 官方仓库](https://github.com/hzwer/ECCV2022-RIFE)
- [AltStore 官网](https://altstore.io/)
- [SideStore 项目](https://github.com/SideStore/SideStore)
- [TrollStore 项目](https://github.com/opa334/TrollStore)

---

**文档版本**：v3.0（完整版）  
**最后更新**：2026-10-15  
**适用系统**：iOS 16.0+  
**开发环境**：GitHub Actions macOS Runner（无需本地 Mac）  
**分发方式**：AltStore / SideStore / TrollStore 侧载，不上架 App Store