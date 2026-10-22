#!/usr/bin/env bash
# SwiftLint 共享脚本 —— CI 与本地 pre-push 共用
# 固定版本 0.57.0，严格模式（warning 升级为 error）
set -euo pipefail

EXPECTED_VERSION="0.57.0"

# ---------- 工具函数 ----------
print_info()  { echo "[lint] $*"; }
print_error()  { echo "[lint] ERROR: $*" >&2; }

# ---------- 安装 SwiftLint ----------
install_swiftlint() {
    print_info "安装 SwiftLint ${EXPECTED_VERSION} ..."

    local os_type
    os_type="$(uname -s)"

    if [ "${os_type}" = "Darwin" ]; then
        # macOS：下载官方 portable 预编译二进制（精确版本）
        local install_dir="/usr/local/bin"
        if [ ! -w "${install_dir}" ] 2>/dev/null; then
            install_dir="${HOME}/.local/bin"
            mkdir -p "${install_dir}"
        fi

        print_info "macOS 平台，下载 portable_swiftlint.zip ..."
        curl -fsSL \
            "https://github.com/realm/SwiftLint/releases/download/${EXPECTED_VERSION}/portable_swiftlint.zip" \
            -o /tmp/swiftlint.zip
        unzip -o /tmp/swiftlint.zip -d "${install_dir}/" >/dev/null
        chmod +x "${install_dir}/swiftlint"
        rm -f /tmp/swiftlint.zip

        # 确保 PATH 包含安装目录
        case ":${PATH}:" in
            *":${install_dir}:"*) ;;
            *) export PATH="${install_dir}:${PATH}" ;;
        esac
    else
        # Linux：从源码构建（GitHub ubuntu-latest runner 已预装 Swift）
        if ! command -v git >/dev/null 2>&1; then
            print_error "Linux 环境缺少 git，无法构建 SwiftLint"
            exit 1
        fi
        if ! command -v swift >/dev/null 2>&1; then
            print_error "Linux 环境缺少 Swift 工具链，无法构建 SwiftLint"
            exit 1
        fi

        print_info "Linux 平台，从 tag ${EXPECTED_VERSION} 构建 SwiftLint ..."
        local build_dir="/tmp/SwiftLint-build"
        rm -rf "${build_dir}"
        git clone --depth 1 --branch "${EXPECTED_VERSION}" \
            https://github.com/realm/SwiftLint.git "${build_dir}"
        cd "${build_dir}"
        make install
        cd - >/dev/null
        rm -rf "${build_dir}"
    fi
}

# ---------- 校验版本 ----------
verify_version() {
    if ! command -v swiftlint >/dev/null 2>&1; then
        install_swiftlint
    fi

    local installed
    installed="$(swiftlint version 2>/dev/null || echo "unknown")"

    if [ "${installed}" != "${EXPECTED_VERSION}" ]; then
        print_info "版本不匹配：期望 ${EXPECTED_VERSION}，当前 ${installed}，重新安装 ..."
        install_swiftlint

        installed="$(swiftlint version 2>/dev/null || echo "unknown")"
        if [ "${installed}" != "${EXPECTED_VERSION}" ]; then
            print_error "安装后版本仍为 ${installed}，期望 ${EXPECTED_VERSION}"
            exit 1
        fi
    fi

    print_info "SwiftLint 版本：${installed}"
}

# ---------- 入口 ----------
# 仅安装模式（CI 工作流调用）
if [ "${1:-}" = "--install-only" ]; then
    verify_version
    print_info "SwiftLint 环境就绪"
    exit 0
fi

# 正常 lint 模式（pre-push 钩子调用）
verify_version

print_info "运行 swiftlint lint --strict --use-alternative-excluding ..."
swiftlint lint --strict --use-alternative-excluding
