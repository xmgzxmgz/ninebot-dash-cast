#!/usr/bin/env python3
"""screen_cast.py —— 把 Mac 屏幕（或一块区域）2fps 推到九号仪表。

为什么不走 ffmpeg 的 avfoundation：那条路要私有屏幕录制授权，在部分环境里
连枚举设备都做不到。`screencapture` 是系统自带命令，稳定得多，代价是帧率
低（截一张 ~0.3s），但对「导航窗口投到仪表」这种静态内容完全够用。

用法：
    python3 screen_cast.py --host 192.168.1.1 --duration 60
    python3 screen_cast.py --host 192.168.1.1 --region 0,0,1280,720 --fps 2
    python3 screen_cast.py --host 127.0.0.1 --duration 5 --dry-run   # 只看包

拼图规则与 ninebot_send.py 一致：等比缩放 + 居中补黑边，H.264 Baseline，
20 字节头 + 1380 分片，视频 5012、心跳 5013。
"""

from __future__ import annotations

import argparse
import os
import queue
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parent))
import h264pipe  # noqa: E402
import protocol  # noqa: E402
import ninebot_send  # noqa: E402
from ninebot_send import Sender, PRESETS  # noqa: E402


def capture(region: str | None, quality: int = 7) -> Image.Image | None:
    """截一张屏幕，返回 PIL 图。quality 越小越快（1–10，screencapture 的口径）。"""
    fd, path = tempfile.mkstemp(suffix=".jpg")
    os.close(fd)
    cmd = ["screencapture", "-x", "-t", "jpg"]
    if region:
        cmd += ["-R", region]
    cmd.append(path)
    try:
        subprocess.run(cmd, check=False, stdout=subprocess.DEVNULL,
                       stderr=subprocess.DEVNULL, timeout=10)
        # screencapture 不做画质参数，尺寸才是耗时大头，这里只兜底文件是否可读
        return Image.open(path).convert("RGB")
    except (OSError, subprocess.SubprocessError, ValueError):
        return None
    finally:
        try:
            os.unlink(path)
        except OSError:
            pass


def letterbox(image: Image.Image, width: int, height: int) -> bytes:
    scale = min(width / image.width, height / image.height)
    size = (max(1, int(image.width * scale)), max(1, int(image.height * scale)))
    canvas = Image.new("RGB", (width, height), (0, 0, 0))
    canvas.paste(image.resize(size, Image.LANCZOS),
                 ((width - size[0]) // 2, (height - size[1]) // 2))
    return canvas.tobytes()


def main() -> int:
    ap = argparse.ArgumentParser(description="Mac 屏幕 → 九号仪表（screencapture 版）")
    ap.add_argument("--host", required=True)
    ap.add_argument("--preset", default="5in", choices=sorted(PRESETS))
    ap.add_argument("--fps", type=float, default=2.0, help="截屏刷新率，默认 2（截一张约 0.3s）")
    ap.add_argument("--duration", type=float, default=0, help="跑多少秒，0 表示一直跑")
    ap.add_argument("--region", help="只截一块区域：x,y,w,h")
    ap.add_argument("--gop", type=int, default=20)
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    if sys.platform != "darwin":
        sys.exit("这个脚本用 macOS 的 screencapture；其他系统请用 bridge/stream_bridge.py")

    preset = dict(PRESETS[args.preset])
    if preset["codec"] != "h264":
        sys.exit("屏幕推送只支持 H.264 预设（5in / 7in）")
    width, height = preset["width"], preset["height"]
    fps = max(1, int(round(args.fps)))
    print(f"[i] {width}x{height} @ {fps}fps → {args.host}:5012"
          + (f"，区域 {args.region}" if args.region else "，全屏"))

    sender = Sender(args.host, {**preset, "fps": fps}, bind_port=True, dry_run=args.dry_run)
    sender.start_heartbeat()

    proc = ninebot_send.spawn_encoder(width, height, fps, preset["bitrate"], args.gop)
    aus: queue.Queue = queue.Queue(maxsize=64)
    stop = threading.Event()
    threading.Thread(target=h264pipe.split_access_units,
                     args=(proc.stdout, aus, stop), daemon=True).start()

    started = time.monotonic()
    stats = {"captured": 0, "failed": 0, "frames": 0, "packets": 0}

    def pump() -> None:
        interval = 1.0 / fps
        due = time.monotonic()
        try:
            while not stop.is_set():
                if args.duration > 0 and time.monotonic() - started >= args.duration:
                    return
                image = capture(args.region)
                if image is None:
                    stats["failed"] += 1
                else:
                    stats["captured"] += 1
                    try:
                        proc.stdin.write(letterbox(image, width, height))
                        proc.stdin.flush()
                    except (BrokenPipeError, OSError):
                        return
                due += interval
                delay = due - time.monotonic()
                if delay > 0:
                    time.sleep(delay)
                elif delay < -interval:
                    due = time.monotonic()  # 截图慢了就别追帧，重置节奏
        finally:
            # 关掉 stdin 让 x264 把缓冲里剩下的帧吐出来，否则最后几帧会丢
            try:
                proc.stdin.close()
            except (OSError, ValueError):
                pass

    threading.Thread(target=pump, daemon=True, name="capture").start()

    index = 0
    try:
        while not stop.is_set():
            try:
                au, key = aus.get(timeout=0.5)
            except queue.Empty:
                if args.duration > 0 and time.monotonic() - started >= args.duration:
                    break
                continue
            ts = int(index * 1000 / fps) & 0xFFFFFFFF
            sender.send_frame(au, ts, key)
            index += 1
            stats["frames"] = index
            stats["packets"] = sender.sent_packets
    except KeyboardInterrupt:
        print("\n[i] 手动中断")
    finally:
        stop.set()
        # 收尾：把编码器里还在排队的 AU 全部取完再关 socket
        drain_until = time.monotonic() + 2.0
        while time.monotonic() < drain_until:
            try:
                au, key = aus.get(timeout=0.3)
            except queue.Empty:
                break
            ts = int(index * 1000 / fps) & 0xFFFFFFFF
            sender.send_frame(au, ts, key)
            index += 1
        stats["frames"] = index
        stats["packets"] = sender.sent_packets
        sender.stop()
        try:
            proc.kill()
        except OSError:
            pass

    elapsed = max(1e-6, time.monotonic() - started)
    print(f"\n[i] 结束：截屏 {stats['captured']} 次（失败 {stats['failed']}）"
          f" / 编码 {stats['frames']} 帧 / {sender.sent_packets} 包 / "
          f"{sender.sent_bytes / 1024:.0f} KiB / pong {sender.pongs} 次")
    if stats["captured"] == 0:
        print("[!] 一张都没截到：系统设置 → 隐私与安全性 → 屏幕录制，勾上终端后重开")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
