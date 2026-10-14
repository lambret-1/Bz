
# iOS 视频补帧 App 开发大纲（云端 CI/CD · 仅侧载版）

## 1. 项目概述

### 1.1 项目目标
开发一款 iOS 应用，支持用户导入本地视频，在设备端快速完成 AI 补帧（如 30fps → 60fps），输出流畅的高帧率视频。
- **最低系统版本**：iOS 16.0
- **核心特性**：完全端侧运行、无需网络、保护隐私
- **开发环境**：无 Mac 电脑，全程使用 GitHub Actions 云端 macOS Runner 完成编译与分发
- **分发方式**：**不上架 App Store**，仅通过 AltStore / SideStore / TrollStore 等工具侧载到个人设备

### 1.2 核心约束
- 无本地 Mac，所有 Xcode 构建均在 GitHub Actions 的 macOS Runner 上执行
- 构建产物为**未签名 IPA**，通过侧载工具安装到 iPhone
- 本项目为个人开发/测试用途，**不提交 App Store 审核，不使用 TestFlight**


## 2. 云端开发环境架构

### 2.1 整体架构

```

┌─────────────────────────────────────────────────────────┐
│                    本地开发环境（Windows/Linux）           │
│  ┌──────────┐  ┌──────────┐  ┌──────────────────────┐  │
│  │ 代码编辑器 │  │  Git CLI  │  │  ios-builder CLI 工具  │  │
│  │ (VS Code) │  │          │  │  (远程构建+下载 IPA)   │  │
│  └──────────┘  └──────────┘  └──────────────────────┘  │
└────────────────────────┬────────────────────────────────┘
│ git push
▼
┌─────────────────────────────────────────────────────────┐
│              GitHub Actions 云端 macOS Runner            │
│                                                         │
│  1. Checkout 代码                                       │
│  2. 安装 Xcode（通过 xcodes 或默认版本）                  │
│  3. 解析 Swift Package / CocoaPods 依赖                 │
│  4. xcodebuild archive（禁用签名）                       │
│  5. 导出未签名 IPA                                      │
│  6. 上传 Artifact / 发布 Release                        │
└────────────────────────┬────────────────────────────────┘
│ 下载 IPA
▼
┌─────────────────────────────────────────────────────────┐
│                    本地设备侧载方案                       │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐  │
│  │  AltStore    │  │  SideStore   │  │  TrollStore  │  │
│  │ (7天过期)    │  │ (无线侧载)    │  │ (永久，特定版本)│  │
│  └──────────────┘  └──────────────┘  └──────────────┘  │
└─────────────────────────────────────────────────────────┘

```

### 2.2 工具选型

| 工具 | 用途 | 适用场景 | 费用 |
| :--- | :--- | :--- | :--- |
| **ios-builder** | 一键初始化 GitHub Actions 工作流、远程构建、下载 IPA | 快速上手，简化 CLI 操作 | 免费 |
| **手动 GitHub Actions 工作流** | 自定义构建流程，精细控制每个步骤 | 需要定制化构建 | 免费（公共仓库） |
| **AltStore / SideStore** | 将未签名 IPA 侧载到 iPhone | 个人测试 | 免费 |
| **TrollStore** | 永久安装未签名 IPA | 特定 iOS 版本 | 免费 |


## 3. GitHub Actions 工作流设计

### 3.1 核心工作流文件

在仓库根目录创建 `.github/workflows/ios-build.yml`：

```yaml
name: iOS Build

on:
  push:
    branches: [main, develop]
  workflow_dispatch:  # 支持手动触发

jobs:
  build:
    runs-on: macos-15  # 使用最新的 macOS Runner

    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Show Xcode version
        run: xcodebuild -version

      - name: Install xcodegen (可选，如使用 XcodeGen 管理工程)
        run: brew install xcodegen

      - name: Generate Xcode project
        run: xcodegen generate

      - name: Resolve Swift Packages
        run: |
          xcodebuild -resolvePackageDependencies \
            -project YourApp.xcodeproj \
            -scheme YourApp

      - name: Archive (Unsigned)
        run: |
          xcodebuild archive \
            -project YourApp.xcodeproj \
            -scheme YourApp \
            -configuration Release \
            -destination 'generic/platform=iOS' \
            -archivePath build/YourApp.xcarchive \
            CODE_SIGN_IDENTITY="" \
            CODE_SIGNING_REQUIRED=NO \
            CODE_SIGNING_ALLOWED=NO

      - name: Export Unsigned IPA
        run: |
          # 从未签名的 xcarchive 中提取 .app 并打包为 IPA
          mkdir -p build/Payload
          cp -r build/YourApp.xcarchive/Products/Applications/YourApp.app \
                build/Payload/
          cd build && zip -r YourApp-unsigned.ipa Payload/

      - name: Upload IPA Artifact
        uses: actions/upload-artifact@v4
        with:
          name: YourApp-unsigned-ipa
          path: build/YourApp-unsigned.ipa
```

关键点：

· runs-on: macos-15 使用 GitHub 托管的 macOS Runner，公共仓库完全免费
· CODE_SIGNING_ALLOWED=NO 禁用代码签名，生成未签名 IPA
· 未签名 IPA 需要通过 AltStore / SideStore / Sideloadly 等工具侧载到设备。

3.2 使用 ios-builder 简化流程

ios-builder 可自动完成上述配置。安装方式：

```bash
# macOS/Linux/WSL
curl -sSL https://raw.githubusercontent.com/MobAI-App/ios-builder/main/install.sh | bash

# 或 Homebrew
brew install mobai-app/tap/ios-builder
```

使用流程：

```bash
builder auth github          # 认证 GitHub
cd your-ios-project
builder init                 # 自动生成工作流并提交
builder ios build            # 触发远程构建，下载 IPA 到 ./dist/
builder ios build --unsigned  # 生成未签名 IPA
```

builder init 会自动检测项目框架（Native iOS / Flutter / React Native / Expo 等），并生成对应的工作流配置。

4. 签名与分发策略（仅侧载）

4.1 分发方式

本项目不上架 App Store，因此仅使用免费侧载方案。

分发方式 前提条件 有效期 适合阶段
TrollStore 特定 iOS 版本 永久 开发测试（如设备支持）
AltStore 任意 iOS 7 天（需重签） 日常开发测试
SideStore 任意 iOS 7 天（无线刷新） 日常开发测试
Sideloadly 任意 iOS 7 天 初次安装测试

4.2 免费侧载操作步骤

1. 从 GitHub Actions Artifacts 或 Release 下载 YourApp-unsigned.ipa
2. 在 iPhone 上安装 AltStore 或 SideStore
3. 通过 AltStore 导入 IPA 文件完成安装
4. 应用每 7 天 过期，需在 AltStore 中刷新（SideStore 支持无线自动刷新）

⚠️ 注意：免费侧载方案仅适合个人开发测试，请勿用于对外分发。

5. 开发阶段规划（云端版）

阶段一：环境搭建与技术验证

□ 创建 GitHub 仓库，初始化 Xcode 工程
□ 配置 ios-build.yml 工作流，验证基础构建通过
□ 在本地 Windows/Linux 上使用 builder ios build 跑通远程构建
□ 下载未签名 IPA，通过 AltStore 安装到 iPhone 验证
□ 在 Mac 上（借用或云 Mac）完成 RIFE Lite 模型转换（Core ML 转换必须在 Mac 上执行一次，之后即可将 .mlpackage 提交到仓库）

阶段二：核心管线开发

□ 实现 Metal 预处理 Shader（BGRA → NCHW）
□ 实现 Metal 后处理 Shader（Sigmoid / Warp / Blend）
□ 封装 Core ML 推理接口
□ 每次推送代码后，通过 GitHub Actions 自动构建并下载 IPA 到真机测试

阶段三：视频流集成

□ 接入 AVAssetReader / AVAssetWriter
□ 处理时间戳（PTS）管理与音视频同步
□ 使用 CVPixelBufferPool 优化内存
□ 实现进度回调与取消功能

阶段四：性能优化与适配

□ 构建异步流水线（解码 / 推理 / 编码并行）
□ 设备分级：根据芯片动态调整分辨率
□ 温度监控与自动降级
□ 内存峰值优化

以下为第 5 章「UI 与用户体验」的细化版，可直接替换原大纲中的阶段 5。本版本按照设计原则 → 信息架构 → 页面详细设计 → 交互与反馈 → 异常处理 → 开发任务拆解的结构展开，适合直接落地为 SwiftUI 代码。

---

5. UI 与用户体验（细化版）

5.1 设计原则与视觉风格

核心设计原则：

· 极简优先：用户只需三步（导入 → 选参数 → 导出），避免专业术语（如 RIFE、ANE、光流）。
· 进度透明：AI 补帧耗时较长，必须让用户随时知道“在做什么”、“还剩多久”。
· 容错友好：视频格式、内存不足、过热等异常需有清晰的引导，而非直接崩溃。
· 隐私安全感：明确提示“所有处理均在本地完成，视频不会上传”。

视觉风格建议：

· 风格：深色模式为主（便于预览视频），搭配高对比度强调色（如系统蓝 / 青色）。
· 字体：使用系统 SF Pro，标题用 .title2 / .headline，正文用 .body / .subheadline。
· 图标：SF Symbols，保持圆角与统一线宽。
· 动效：使用 .animation(.easeInOut) 实现页面切换和进度变化，避免过度动画导致性能下降。

---

5.2 信息架构与导航设计

页面流转图：

```
[首页 / 导入]
    │ 选择视频
    ▼
[参数设置] ←──┐
    │ 确认参数 │ 返回修改
    ▼         │
[处理中] ─────┘
    │ 完成
    ▼
[结果预览] ──→ [保存到相册] ──→ [完成 / 再次处理]
```

导航方式：

· 使用 NavigationStack 管理主流程。
· 首页 → 设置：NavigationLink / sheet 弹出。
· 处理中：全屏覆盖（fullScreenCover），禁止返回手势，防止误操作。
· 结果页：push 进入，保留返回首页的路径。

---

5.3 页面详细设计

页面 1：首页 / 导入

功能：引导用户导入视频，展示最近处理记录。

UI 元素：

· 顶部：App 名称 + 设置入口（齿轮图标）
· 中央：大号导入卡片
  · 图标：photo.on.rectangle.angled
  · 主文案：「导入视频开始补帧」
  · 副文案：「支持 30fps → 60fps / 120fps，完全本地处理」
  · 按钮：「从相册选择」 / 「从文件选择」
· 底部：最近记录列表（最多 5 条）
  · 显示缩略图、文件名、处理时间、输出帧率预估
  · 点击可重新预览或再次处理

空状态：显示引导插画 + 「还没有处理记录，导入一个视频试试吧耗时」。

权限处理：

· 首次点击导入时，请求相册 / 文件访问权限。
· 被拒绝时，显示「去设置开启权限」按钮，跳转系统设置。

---

页面 2：参数设置

功能：让用户选择补帧倍数、输出分辨率、是否开启快速模式。

UI 元素：

· 视频预览卡片：显示视频缩略图、时长、原始帧率
· 补帧倍数（分段控件 Picker）：
  · 2x（30fps → 60fps）
  · 4x（30fps → 120fps，仅 A16 及以上可用）
· 输出分辨率（分段控件）：
  · 自动（推荐，根据设备性能动态选择）
  · 720p（省电、快速）
  · 1080p（画质优先）
· 快速模式（Toggle）：
  · 开启后使用 Metal 帧混合，速度极快但画质略降
  · 副文案：「适合短视频预览，不适合专业输出」
· 预估信息卡片：
  · 「预计耗时：约 2 分钟」
  · 「预计输出大小：约 45 MB」
· 底部主按钮：「开始补帧」

交互细节：

· 选择 4x 但设备不支持时，自动禁用并提示「当前设备不支持 4x，请选择 2x」。
  -根据设备芯片和分辨率动态计算，给用户心理预期。

---

页面 3：处理中

功能：展示处理进度，支持取消，防止屏幕休眠。

UI 元素：

· 顶部：视频缩略图 + 文件名
· 中央：环形进度条（ProgressView / 自定义 Circle）
  · 显示百分比
  · 下方显示「已处理 120 / 300 帧」
· 状态文案：
  · 「正在解码视频…」
  · 「AI 正在计算光流…」
  · 「正在编码输出…」
· 底部：
  · 「预计剩余时间：约 1 分 20 秒」
  · 「取消」按钮（二次确认弹窗）
  · 提示：「处理期间请保持 App 在前台，锁屏会暂停处理」

交互细节：

· 处理期间调用 UIApplication.shared.isIdleTimerDisabled = true 防止息屏。
· 取消时弹出确认框：「确定要取消吗？已处理的部分将被丢弃」。
· 支持后台短暂运行（beginBackgroundTask），切后台超过 30 秒自动暂停并提示。

---

页面 4：结果预览与导出

功能：预览补帧后的视频，保存到相册或分享。

UI 元素：

· 视频播放器（AVPlayer + VideoPlayer）：
  · 支持播放 / 暂停
  · 显示帧率标识（如「60fps」）
· 对比信息：
  · 「原始：30fps / 12.5 MB」
  · 「补帧后：60fps / 45 MB」
· 操作按钮：
  · 「保存到相册」（主按钮）
  · 「分享」（系统分享面板）
  · 「再次处理」（返回设置页）
· 保存成功提示：Toast 或 Alert：「已保存到相册」

交互细节：

· 保存前检查相册权限，被拒绝时引导去设置。
· 保存成功后自动返回首页，并刷新最近记录。
· 支持长按视频卡片弹出「删除」「分享」菜单。

---

5.4 状态管理与全局反馈

状态 UI 表现 处理方式
加载中 骨架屏 / 转圈 ProgressView + 文案
处理中 环形进度条 + 剩余时间 禁止返回，防息屏
成功 Toast「处理完成」 自动跳转结果页
失败 Alert + 错误码 提供「重试」或「反馈」
权限拒绝 引导弹窗 跳转系统设置
存储不足 Alert 提示清理空间
设备过热 提示条 建议降分辨率或稍后重试

触觉反馈（Haptic）：

· 开始处理：UIImpactFeedbackGenerator(style: .medium)
· 处理完成：UINotificationFeedbackGenerator(.success)
· 错误提示：UINotificationFeedbackGenerator(.error)

---

5.5 无障碍与本地化

· VoiceOver：为所有按钮、进度条、视频卡片添加 accessibilityLabel。
· 动态字体：使用 .dynamicTypeSize 支持系统字体缩放。
· 深色模式：默认跟随系统，视频预览区使用纯黑背景。
· 本地化：
  · 优先支持中文（简体）和英文。
  · 所有文案使用 Localizable.strings 管理，避免硬编码。

---

5.6 开发任务拆解与验收标准

任务清单：

□ 搭建 SwiftUI 工程结构，配置 NavigationStack 与全局主题
□ 实现首页：导入按钮、最近记录列表、空状态、权限请求
□ 实现参数设置页：分段控件、Toggle、预估信息卡片
□ 实现处理页：环形进度条、状态文案、取消确认、防息屏
□ 实现结果页：AVPlayer 预览、保存相册、分享、再次处理
□ 封装全局状态管理：ObservableObject / @Observable
□ 接入触觉反馈与 Toast 提示
□ 适配深色模式、动态字体、VoiceOver
□ 中英文本地化（可选）
□ 真机测试各页面交互与异常处理

验收标准：

· 完整流程（导入 → 设置 → 处理 → 保存）无崩溃、无卡顿
· 进度实时更新，剩余时间估算误差 < 20%
· 取消操作响应及时，临时文件被清理
· 权限拒绝、内存不足、过热等异常均有明确提示
· 深色模式、动态字体下 UI 无布局错乱
· 通过 VoiceOver 可完成核心操作

交付物：

· SwiftUI 页面源码
· 全局状态管理与主题配置
· 本地化文件
· UI 验收测试记录
· 演示视频或截图

---

6. CI/CD 工作流进阶配置

6.1 缓存优化

在 GitHub Actions 中缓存 Swift Package 依赖和 DerivedData，可将构建时间缩短 30%–50%：

```yaml
      - name: Cache Swift Packages
        uses: actions/cache@v4
        with:
          path: |
            ~/Library/Caches/org.swift.swiftpm
            ~/Library/Developer/Xcode/DerivedData
          key: ${{ runner.os }}-spm-${{ hashFiles('**/Package.resolved') }}
          restore-keys: |
            ${{ runner.os }}-spm-
```

6.2 多设备模拟器测试

```yaml
    strategy:
      matrix:
        destination:
          - 'platform=iOS Simulator,name=iPhone 16,OS=latest'
          - 'platform=iOS Simulator,name=iPhone 16 Pro,OS=latest'
    steps:
      - name: Run Tests
        run: |
          xcodebuild test \
            -project YourApp.xcodeproj \
            -scheme YourApp \
            -destination '${{ matrix.destination }}'
```

6.3 自动发布 Release

```yaml
      - name: Create Release
        if: startsWith(github.ref, 'refs/tags/v')
        uses: softprops/action-gh-release@v2
        with:
          files: build/YourApp-unsigned.ipa
```

6.4 关键注意事项

· 版本选择：macos-15 对应最新稳定版 Xcode，macos-26 对应更新的预览版。建议在构建步骤中先运行 xcodebuild -version 确认环境

7. 交付物清单

□ GitHub 仓库（包含 .github/workflows/ios-build.yml）
□ Core ML .mlpackage 模型文件
□ Metal Shader 源码
□ Swift 核心处理管线代码
□ SwiftUI 界面代码
□ ios-builder 配置（如使用）
□ 未签名 IPA 构建产物（用于侧载）

8. 参考资源

· ios-builder — 无 Mac iOS 开发 CLI 工具
· GitHub Actions 免费 macOS Runner 说明
· Core ML 官方文档
· RIFE 官方仓库
· AltStore 官网
· SideStore 项目
· TrollStore 项目

---

文档版本：v2.1（云端 CI/CD · 仅侧载版）
最后更新：2026-10-15
适用系统：iOS 16.0+
开发环境：GitHub Actions macOS Runner（无需本地 Mac）
分发方式：AltStore / SideStore / TrollStore 侧载

