#!/usr/bin/env python3
"""
iOS 崩溃日志解析脚本
支持两种格式：
1. .ips 格式（iOS 系统崩溃日志）：提取十六进制地址、UUID、基地址，供 atos 符号化
2. .txt 格式（App 内部 CrashLogger 导出的报告）：直接提取已符号化的调用栈

自动识别文件格式，输出统一的解析结果
"""

import json
import sys
import base64
import re
import os


def detect_format(content):
    """检测文件格式"""
    stripped = content.strip()
    # .txt 格式：包含 "崩溃日志" 或 "崩溃时间" 标记
    if '崩溃日志' in content or '崩溃时间' in content or 'CRASH LOG' in content.upper():
        return 'txt'
    # .ips 格式：第一行是 JSON（以 { 开头）
    if stripped.startswith('{'):
        return 'ips'
    # 纯 base64 格式
    if '\n' not in stripped and re.match(r'^[A-Za-z0-9+/=]+$', stripped):
        return 'ips_base64'
    # 尝试解析第一行是否为 JSON
    first_line = stripped.split('\n')[0].strip()
    if first_line.startswith('{'):
        try:
            json.loads(first_line)
            return 'ips'
        except json.JSONDecodeError:
            pass
    return 'unknown'


def parse_txt_report(content):
    """解析 App 内部 CrashLogger 导出的 TXT 格式报告"""
    result = {
        'format': 'txt',
        'version': 'Unknown',
        'build': 'Unknown',
        'uuid': 'N/A (TXT格式已符号化)',
        'load_address': 'N/A',
        'app_name': 'FrameInterpolation',
        'crash_time': 'Unknown',
        'crash_type': 'Unknown',
        'crash_reason': 'Unknown',
        'call_stack': [],
        'addresses': []
    }

    lines = content.splitlines()
    in_call_stack = False

    for line in lines:
        line_stripped = line.strip()

        # 提取基本信息
        if line_stripped.startswith('崩溃时间:') or line_stripped.startswith('Crash Time:'):
            result['crash_time'] = line_stripped.split(':', 1)[1].strip()
        elif line_stripped.startswith('崩溃类型:') or line_stripped.startswith('Crash Type:'):
            result['crash_type'] = line_stripped.split(':', 1)[1].strip()
        elif line_stripped.startswith('崩溃原因:') or line_stripped.startswith('Crash Reason:'):
            result['crash_reason'] = line_stripped.split(':', 1)[1].strip()
        elif line_stripped.startswith('应用版本:') or line_stripped.startswith('App Version:'):
            result['version'] = line_stripped.split(':', 1)[1].strip()
        elif line_stripped.startswith('构建版本:') or line_stripped.startswith('Build Version:'):
            result['build'] = line_stripped.split(':', 1)[1].strip()
        elif line_stripped.startswith('应用名称:') or line_stripped.startswith('App Name:'):
            result['app_name'] = line_stripped.split(':', 1)[1].strip()

        # 检测调用栈区域开始
        if line_stripped.startswith('调用栈') or line_stripped.upper().startswith('CALL STACK'):
            in_call_stack = True
            continue

        # 检测调用栈区域结束
        if in_call_stack:
            if line_stripped.startswith('=====') or line_stripped.startswith('崩溃日志结束'):
                in_call_stack = False
                continue
            if line_stripped and not line_stripped.startswith('---'):
                result['call_stack'].append(line_stripped)
                # 尝试提取十六进制地址
                addr_match = re.search(r'0x[0-9a-fA-F]+', line_stripped)
                if addr_match:
                    result['addresses'].append(addr_match.group())

    return result


def parse_multiple_json(text):
    """解析文本中连续的多个 JSON 对象"""
    decoder = json.JSONDecoder()
    objects = []
    idx = 0
    while idx < len(text):
        while idx < len(text) and text[idx] in ' \n\r\t':
            idx += 1
        if idx >= len(text):
            break
        try:
            obj, end = decoder.raw_decode(text, idx)
            objects.append(obj)
            idx = end
        except json.JSONDecodeError:
            break
    return objects


def parse_ips_file(content):
    """解析 .ips 格式崩溃日志"""
    stripped = content.strip()
    # 纯 base64 格式
    if '\n' not in stripped and re.match(r'^[A-Za-z0-9+/=]+$', stripped):
        try:
            decoded = base64.b64decode(stripped).decode('utf-8')
            objects = parse_multiple_json(decoded)
            if len(objects) >= 2:
                header = objects[0]
                crash_data = objects[1]
            elif len(objects) == 1:
                header = {}
                crash_data = objects[0]
            else:
                print("错误: base64 解码后无有效 JSON")
                return None
        except Exception as e:
            print(f"错误: base64 解码失败: {e}")
            return None
    else:
        # 多行格式：第一行是 header JSON，剩余行拼接成 body JSON
        lines = stripped.splitlines()
        if len(lines) < 2:
            print("错误: .ips 文件行数不足")
            return None
        try:
            header = json.loads(lines[0])
            # body 可能跨多行（格式化的 JSON），需要拼接剩余所有行
            body_text = '\n'.join(lines[1:])
            crash_data = json.loads(body_text)
        except json.JSONDecodeError as e:
            print(f"错误: JSON 解析失败: {e}")
            print(f"第一行前100字符: {lines[0][:100]}")
            print(f"剩余行前100字符: {body_text[:100] if 'body_text' in dir() else 'N/A'}")
            return None

    # 提取版本信息
    app_version = header.get('app_version', 'Unknown')
    build_version = header.get('build_version', header.get('bundleVersion', '1'))

    # 寻找崩溃线程
    faulting_thread = None
    for t in crash_data.get('threads', []):
        if t.get('triggered'):
            faulting_thread = t
            break
    if not faulting_thread:
        fault_idx = crash_data.get('faultingThread', 0)
        threads = crash_data.get('threads', [])
        if fault_idx < len(threads):
            faulting_thread = threads[fault_idx]
    if not faulting_thread:
        print("错误: 未找到崩溃线程")
        return None

    # 寻找应用镜像
    app_image = None
    for img in crash_data.get('usedImages', []):
        name = img.get('name', '')
        path = img.get('path', '')
        if 'FrameInterpolation' in name or 'FrameInterpolation' in path:
            app_image = img
            break
    if not app_image:
        print("错误: 未找到 FrameInterpolation 镜像信息")
        return None

    load_address = hex(app_image['base'])
    uuid = app_image.get('uuid', 'Unknown')

    # 提取崩溃地址
    addresses = []
    for frame in faulting_thread.get('frames', []):
        img_idx = frame.get('imageIndex', -1)
        if img_idx >= 0 and img_idx < len(crash_data.get('usedImages', [])):
            img = crash_data['usedImages'][img_idx]
            if 'FrameInterpolation' in img.get('name', ''):
                addr = hex(frame['imageOffset'] + app_image['base'])
                addresses.append(addr)
                if len(addresses) >= 20:
                    break

    return {
        'format': 'ips',
        'version': app_version,
        'build': build_version,
        'uuid': uuid,
        'load_address': load_address,
        'app_name': app_image.get('name', 'Unknown'),
        'crash_time': header.get('timestamp', 'Unknown'),
        'crash_type': crash_data.get('exception', {}).get('type', 'Unknown'),
        'crash_reason': crash_data.get('exception', {}).get('signal', 'Unknown'),
        'call_stack': [],
        'addresses': addresses
    }


def main(file_path):
    if not os.path.exists(file_path):
        print(f"错误: 文件不存在: {file_path}")
        sys.exit(1)

    with open(file_path, 'r', encoding='utf-8') as f:
        content = f.read()

    fmt = detect_format(content)
    print(f"检测到格式: {fmt}", file=sys.stderr)

    if fmt in ('ips', 'ips_base64'):
        result = parse_ips_file(content)
        if result is None:
            sys.exit(1)
    elif fmt == 'txt':
        result = parse_txt_report(content)
    else:
        print("错误: 无法识别的文件格式")
        print("支持的格式: .ips (iOS系统崩溃日志), .txt (App内部CrashLogger导出报告)")
        sys.exit(1)

    # 输出统一格式
    print(f"FORMAT={result['format']}")
    print(f"VERSION={result['version']}")
    print(f"BUILD={result['build']}")
    print(f"UUID={result['uuid']}")
    print(f"LOAD_ADDRESS={result['load_address']}")
    print(f"APP_NAME={result['app_name']}")
    print(f"CRASH_TIME={result['crash_time']}")
    print(f"CRASH_TYPE={result['crash_type']}")
    print(f"CRASH_REASON={result['crash_reason']}")
    print("--- CRASH ADDRESSES ---")

    if result['format'] == 'txt':
        print("# TXT格式调用栈已符号化，无需atos处理")
        for frame in result['call_stack']:
            print(frame)
    else:
        for addr in result['addresses']:
            print(addr)

    if not result['addresses'] and not result['call_stack']:
        print("警告: 未提取到崩溃地址或调用栈", file=sys.stderr)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("用法: python3 parse_ips.py <崩溃日志文件>")
        print("支持格式: .ips (iOS系统崩溃日志), .txt (App内部CrashLogger导出报告)")
        sys.exit(1)
    main(sys.argv[1])
