#!/usr/bin/env python3
"""stream_bridge.py —— 把任意视频源桥接到九号仪表。

它解决的是「源不是我们生成」的场景：AirPlay 接收端的窗口、CarPlay 车机盒子的
Electron 窗口（node-carplay）、摄像头、RTSP 流、整个桌面……统一走 ffmpeg 进来，
编码成仪表要的 H.264 Baseline，再套上逆向出来的 20 字节头发 UDP 5012。

用法：
    # 列出当前所有可见窗口标题（找 AirPlay 接收端 / node-carplay 窗口用）
    python stream_bridge.py --list-windows

    # 整个桌面 → 仪表
    python stream_bridge.py --host 192.168.1.1 --source desktop

    # 只抓某个窗口（标题模糊匹配，忽略大小写）
    python stream_bridge.py --host 192.168.1.1 --source window:AirServer

    # 抓屏幕一块区域 x,y,w,h
    python stream_bridge.py --host 192.168.1.1 --source region:0,0,1280,720

    # 安卓设备屏幕（DiPlay 跑 CarPlay，用 USB 线连电脑抓屏）
    python stream_bridge.py --host 192.168.1.1 --source adb

    # 任意能把 H.264 吐到 stdout 的命令
    python stream_bridge.py --host 192.168.1.1 --source "pipe:<命令>"

    # 网络流 / 本地文件
    python stream_bridge.py --host 192.168.1.1 --source rtsp://192.168.1.50:8554/carplay

    # 不联网，只看包
    python stream_bridge.py --host 127.0.0.1 --source desktop --dry-run --duration 2

Windows 上走 gdigrab；macOS / Linux 需要自带 ffmpeg 并换用 avfoundation / x11grab，
源码里 `_capture_args()` 一处改就行。
"""

from __future__ import annotations

import argparse
import os
import queue
import subprocess
import sys
import threading
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))

import h264pipe  # noqa: E402

from ninebot_send import PRESETS, Sender  # noqa: E402


def list_windows() -> int:
    if sys.platform != "win32":
        print("窗口枚举目前只实现 Windows；其他平台请直接用 --source desktop 或网络流")
        return 1
    import ctypes
    from ctypes import wintypes

    user32 = ctypes.WinDLL("user32", use_last_error=True)
    titles: list[str] = []

    @ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND, wintypes.LPARAM)
    def enum_proc(hwnd, _lparam):
        if not user32.IsWindowVisible(hwnd):
            return True
        length = user32.GetWindowTextLengthW(hwnd)
        if length == 0:
            return True
        buf = ctypes.create_unicode_buffer(length + 2)
        user32.GetWindowTextW(hwnd, buf, length + 2)
        title = buf.value.strip()
        if title:
            titles.append(title)
        return True

    user32.EnumWindows(enum_proc, 0)
    for title in sorted(set(titles)):
        print(title)
    print(f"\n共 {len(set(titles))} 个可见窗口")
    return 0


def _capture_args(source: str, fps: int) -> list[str]:
    """把 --source 翻译成 ffmpeg 输入参数。"""
    if source == "desktop":
        return ["-f", "gdigrab", "-framerate", str(fps), "-i", "desktop"]
    if source.startswith("window:"):
        title = source.split(":", 1)[1].strip()
        return ["-f", "gdigrab", "-framerate", str(fps), "-i", f"title={title}"]
    if source.startswith("region:"):
        parts = source.split(":", 1)[1].split(",")
        if len(parts) != 4:
            sys.exit("region 格式：region:x,y,w,h")
        x, y, w, h = (int(v) for v in parts)
        return ["-f", "gdigrab", "-framerate", str(fps),
                "-offset_x", str(x), "-offset_y", str(y),
                "-video_size", f"{w}x{h}", "-i", "desktop"]
    if source.startswith(("rtsp://", "rtmp://", "http://", "https://", "tcp://", "udp://")):
        return ["-i", source]
    if Path(source).exists():
        return ["-re", "-stream_loop", "-1", "-i", source]
    sys.exit(f"无法识别的来源：{source}（支持 desktop / window:标题 / region:x,y,w,h / 网络流 / 本地文件）")


def _producer(source: str) -> list[str] | None:
    """需要"先跑一个进程把 H.264 喂给 ffmpeg"的来源。

    - `adb[:序列号]`：安卓设备屏幕录制（DiPlay 之类 CarPlay 接收端跑在安卓上）
    - `pipe:命令`：任意能往 stdout 吐 H.264 的命令
    """
    if source.startswith("adb"):
        serial = source.split(":", 1)[1].strip() if ":" in source else ""
        # 允许用 ADB 环境变量指定 adb 路径（没加进 PATH 时很常见）
        cmd = [os.environ.get("ADB", "adb")]
        if serial:
            cmd += ["-s", serial]
        # screenrecord 直接输出 H.264，不用先落盘
        cmd += ["exec-out", "screenrecord", "--output-format=h264",
                "--bit-rate", "8000000", "--time-limit", "180", "-"]
        return cmd
    if source.startswith("pipe:"):
        # 直接按空白切分后 spawn，不经过 shell（Windows 上避免 cmd.exe 转义地狱）
        return _split_command(source.split(":", 1)[1])
    return None


def _split_command(text: str) -> list[str]:
    import shlex

    parts = shlex.split(text, posix=(sys.platform != "win32"))
    return [p.strip('"') if len(p) > 1 and p[0] == p[-1] == '"' else p for p in parts]


def build_command(source: str, width: int, height: int, fps: int,
                  bitrate: int, gop: int) -> tuple[list[str], list[str] | None]:
    """返回 (ffmpeg 命令, 生产者命令或 None)。"""
    producer = _producer(source)
    if producer is not None:
        # 实测：管道喂裸 H.264 时不能再加 -fflags nobuffer / -flags low_delay /
        # -analyzeduration 0，任何一个都会让解码端探不到帧、输出 0 字节。
        head = ["-f", "h264", "-i", "-"]
    else:
        head = _capture_args(source, fps)
    ffmpeg = [
        h264pipe.ffmpeg_path(), "-v", "error",
        *head,
        "-vf", h264pipe.scale_filter(width, height),
        *h264pipe.encoder_args(width, height, fps, bitrate, gop),
    ]
    return ffmpeg, producer


def main() -> int:
    ap = argparse.ArgumentParser(description="视频源 → 九号仪表桥接器")
    ap.add_argument("--list-windows", action="store_true", help="列出可见窗口标题后退出")
    ap.add_argument("--host", help="仪表 IP")
    ap.add_argument("--source", default="desktop", help="desktop | window:标题 | region:x,y,w,h | 流地址 | 文件")
    ap.add_argument("--preset", default="5in", choices=sorted(PRESETS))
    ap.add_argument("--fps", type=int)
    ap.add_argument("--bitrate", type=int)
    ap.add_argument("--gop", type=int, default=20)
    ap.add_argument("--duration", type=float, default=0)
    ap.add_argument("--no-bind-port", action="store_true")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    if args.list_windows:
        return list_windows()
    if not args.host:
        ap.error("需要 --host")

    preset = dict(PRESETS[args.preset])
    if args.fps:
        preset["fps"] = args.fps
    if args.bitrate:
        preset["bitrate"] = args.bitrate
    if preset["codec"] != "h264":
        sys.exit("桥接器只支持 H.264 预设（5in / 7in）")

    cmd, producer_cmd = build_command(args.source, preset["width"], preset["height"],
                                      preset["fps"], preset["bitrate"], args.gop)
    if producer_cmd:
        print("[i] 采集进程：", " ".join(producer_cmd))
    else:
        print("[i] ffmpeg 输入：", " ".join(_capture_args(args.source, preset["fps"])))
    print(f"[i] 输出 {preset['width']}x{preset['height']} {preset['fps']}fps "
          f"{preset['bitrate']}kbps → {args.host}:5012")

    sender = Sender(args.host, preset, bind_port=not args.no_bind_port, dry_run=args.dry_run)
    sender.start_heartbeat()

    stop = threading.Event()
    producer = None
    if producer_cmd:
        producer = subprocess.Popen(producer_cmd, stdin=subprocess.DEVNULL,
                                    stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        proc = subprocess.Popen(cmd, stdin=producer.stdout, stdout=subprocess.PIPE,
                                stderr=subprocess.DEVNULL, bufsize=0)
        producer.stdout.close()
    else:
        proc = subprocess.Popen(cmd, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                stderr=subprocess.DEVNULL, bufsize=0)
    aus: queue.Queue = queue.Queue(maxsize=32)
    threading.Thread(target=h264pipe.split_access_units, args=(proc.stdout, aus, stop),
                     daemon=True, name="splitter").start()

    started = time.monotonic()
    index = 0
    try:
        while not stop.is_set():
            if args.duration > 0 and time.monotonic() - started >= args.duration:
                break
            if proc.poll() is not None and aus.empty():
                print("[!] ffmpeg 已退出，检查来源是否还在（窗口标题变了？流断了？）")
                break
            try:
                au, key = aus.get(timeout=0.5)
            except queue.Empty:
                continue
            ts = int(index * 1000 / preset["fps"]) & 0xFFFFFFFF
            sender.send_frame(au, ts, key)
            index += 1
    except KeyboardInterrupt:
        print("\n[i] 手动中断")
    finally:
        stop.set()
        sender.stop()
        for handle in (proc, producer):
            try:
                if handle:
                    handle.kill()
            except OSError:
                pass
        elapsed = max(1e-6, time.monotonic() - started)
        kbps = sender.sent_bytes * 8 / elapsed / 1000
        print(f"[i] 结束：{sender.sent_frames} 帧 / {sender.sent_packets} 包 / "
              f"{kbps:.0f} kbps / pong {sender.pongs} 次 / RTT {sender.rtt_ms} ms")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
