#!/usr/bin/env python3
"""
iOS .ips 崩溃日志解析脚本
提取崩溃线程地址、应用基地址、UUID、版本号，供 atos 符号化使用

支持两种 .ips 格式：
1. 多行格式：第一行 header JSON，第二行 body JSON
2. 单行 base64 格式：整个文件 base64 编码，解码后含多个 JSON 对象
"""

import json
import sys
import base64
import re


def parse_ips(ips_path):
    with open(ips_path, 'r', encoding='utf-8') as f:
        content = f.read().strip()

    # 尝试判断格式：如果是纯 base64（无空格无换行），先解码
    if '\n' not in content and re.match(r'^[A-Za-z0-9+/=]+$', content):
        try:
            decoded = base64.b64decode(content).decode('utf-8')
            objects = parse_multiple_json(decoded)
            if len(objects) >= 2:
                header = objects[0]
                crash_data = objects[1]
            elif len(objects) == 1:
                header = {}
                crash_data = objects[0]
            else:
                print("错误: base64 解码后无有效 JSON")
                return
        except Exception as e:
            print(f"错误: base64 解码失败: {e}")
            return
    else:
        # 多行格式
        lines = content.splitlines()
        if len(lines) < 2:
            print("错误: .ips 文件行数不足")
            return
        try:
            header = json.loads(lines[0])
            crash_data = json.loads(lines[1])
        except json.JSONDecodeError as e:
            print(f"错误: JSON 解析失败: {e}")
            return

    # 提取版本信息
    app_version = header.get('app_version', 'Unknown')
    build_version = header.get('build_version', header.get('bundleVersion', '1'))

    # 寻找崩溃线程（triggered = true）
    faulting_thread = None
    for t in crash_data.get('threads', []):
        if t.get('triggered'):
            faulting_thread = t
            break

    if not faulting_thread:
        # 如果没有 triggered 标记，使用 faultingThread 索引
        fault_idx = crash_data.get('faultingThread', 0)
        threads = crash_data.get('threads', [])
        if fault_idx < len(threads):
            faulting_thread = threads[fault_idx]

    if not faulting_thread:
        print("错误: 未找到崩溃线程")
        return

    # 寻找应用镜像（FrameInterpolation）
    app_image = None
    for img in crash_data.get('usedImages', []):
        name = img.get('name', '')
        path = img.get('path', '')
        if 'FrameInterpolation' in name or 'FrameInterpolation' in path:
            app_image = img
            break

    if not app_image:
        print("错误: 未找到 FrameInterpolation 镜像信息")
        print("可用镜像:", [img.get('name', '') for img in crash_data.get('usedImages', [])[:5]])
        return

    load_address = hex(app_image['base'])
    uuid = app_image.get('uuid', 'Unknown')

    # 输出结果
    print(f"VERSION={app_version}")
    print(f"BUILD={build_version}")
    print(f"UUID={uuid}")
    print(f"LOAD_ADDRESS={load_address}")
    print(f"APP_NAME={app_image.get('name', 'Unknown')}")
    print("--- CRASH ADDRESSES ---")

    # 输出崩溃线程中属于应用的帧地址（前 20 帧）
    count = 0
    for frame in faulting_thread.get('frames', []):
        img_idx = frame.get('imageIndex', -1)
        # 只处理应用自身的帧（imageIndex 对应 app_image）
        if img_idx >= 0 and img_idx < len(crash_data.get('usedImages', [])):
            img = crash_data['usedImages'][img_idx]
            if 'FrameInterpolation' in img.get('name', ''):
                addr = hex(frame['imageOffset'] + app_image['base'])
                print(f"{addr}")
                count += 1
                if count >= 20:
                    break

    if count == 0:
        # 如果没有找到应用自身的帧，输出所有帧的地址
        print("警告: 崩溃线程中未找到应用自身帧，输出所有帧地址")
        for frame in faulting_thread.get('frames', [])[:20]:
            img_idx = frame.get('imageIndex', -1)
            if img_idx >= 0 and img_idx < len(crash_data.get('usedImages', [])):
                img = crash_data['usedImages'][img_idx]
                addr = hex(frame['imageOffset'] + img['base'])
                print(f"{addr}  # {img.get('name', 'unknown')}")


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


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("用法: python3 parse_ips.py <崩溃日志.ips>")
        sys.exit(1)
    parse_ips(sys.argv[1])
