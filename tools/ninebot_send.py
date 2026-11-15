#!/usr/bin/env python3
"""ninebot_send.py —— 按逆向规格向九号电动车仪表推流。

用法示例：
    # 只发测试图，5 寸预设，10 秒后自动停
    python ninebot_send.py --host 192.168.1.1 --preset 5in --duration 10

    # 发一张图片（自动等比缩放补黑边）
    python ninebot_send.py --host 192.168.1.1 --source image:nav.png

    # 发视频（用 ffmpeg 解码 + 重编码）
    python ninebot_send.py --host 192.168.1.1 --source video:demo.mp4

    # 不联网，只打印包结构，用来看协议对不对
    python ninebot_send.py --host 127.0.0.1 --preset 5in --dry-run --duration 2

前提：电脑已连上仪表自己开的热点（iOS/Windows 都要手动连），仪表处于投屏接收态。
"""

from __future__ import annotations

import argparse
import os
import queue
import socket
import subprocess
import sys
import threading
import time

try:
    from PIL import Image, ImageDraw
except ImportError:  # pragma: no cover
    sys.exit("缺少 Pillow：pip install -r requirements.txt")

import h264pipe
import protocol
from h264pipe import split_access_units

PRESETS = {
    "5in": dict(width=848, height=480, fps=20, bitrate=2000, codec="h264", chunk=1380,
                note="五寸（KZ110 已验证）"),
    "7in": dict(width=1024, height=600, fps=25, bitrate=2000, codec="h264", chunk=1380,
                note="七寸（需要 KCP 封装，本工具未实现，仅供抓包/调试）"),
    "4.3in": dict(width=480, height=272, fps=10, bitrate=0, codec="jpeg", chunk=1400,
                  note="4.3 寸（JPEG 逐帧，实验）"),
}


# --------------------------------------------------------------------------- #
# 画面来源
# --------------------------------------------------------------------------- #
def render_test_pattern(index: int, width: int, height: int) -> bytes:
    """彩条 + 移动滑块 + 帧计数，用来确认链路通没通。"""
    img = Image.new("RGB", (width, height), (16, 16, 20))
    draw = ImageDraw.Draw(img)
    colors = [(255, 0, 0), (255, 160, 0), (255, 255, 0), (0, 200, 0),
              (0, 180, 255), (60, 60, 255), (200, 0, 255)]
    bar_w = max(1, width // len(colors))
    for i, color in enumerate(colors):
        draw.rectangle([i * bar_w, 0, (i + 1) * bar_w - 1, height // 3], fill=color)
    block = max(8, width // 16)
    x = (index * max(1, width // 40)) % max(1, width - block)
    draw.rectangle([x, height // 2, x + block, height // 2 + block], fill=(255, 255, 255))
    draw.text((8, height // 3 + 8), f"FRAME {index:06d}", fill=(240, 240, 240))
    draw.text((8, height // 3 + 28), f"{width}x{height}", fill=(160, 200, 255))
    return img.tobytes()


def load_image_frame(path: str, width: int, height: int) -> bytes:
    """等比缩放 + 居中补黑边，避免拉伸变形。"""
    src = Image.open(path).convert("RGB")
    scale = min(width / src.width, height / src.height)
    size = (max(1, int(src.width * scale)), max(1, int(src.height * scale)))
    canvas = Image.new("RGB", (width, height), (0, 0, 0))
    canvas.paste(src.resize(size, Image.LANCZOS),
                 ((width - size[0]) // 2, (height - size[1]) // 2))
    return canvas.tobytes()


def video_frames(path: str, width: int, height: int, fps: int):
    """用 ffmpeg 解码成 rgb24 裸流，按帧产出。"""
    ffmpeg = ffmpeg_path()
    cmd = [ffmpeg, "-v", "error", "-re", "-stream_loop", "-1", "-i", path,
           "-vf", h264pipe.scale_filter(width, height),
           "-r", str(fps), "-pix_fmt", "rgb24", "-f", "rawvideo", "-"]
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    frame_bytes = width * height * 3
    try:
        while True:
            buf = proc.stdout.read(frame_bytes)
            if len(buf) < frame_bytes:
                break
            yield buf
    finally:
        proc.kill()


def ffmpeg_path() -> str:
    return h264pipe.ffmpeg_path()


# --------------------------------------------------------------------------- #
# H.264 编码（ffmpeg 管道，Annex-B 输出）
# --------------------------------------------------------------------------- #
def spawn_encoder(width: int, height: int, fps: int, bitrate: int, gop: int) -> subprocess.Popen:
    cmd = [
        h264pipe.ffmpeg_path(), "-v", "error",
        "-f", "rawvideo", "-pix_fmt", "rgb24", "-s", f"{width}x{height}",
        "-r", str(fps), "-i", "-",
        *h264pipe.encoder_args(width, height, fps, bitrate, gop),
    ]
    return h264pipe.spawn(cmd, stdin_pipe=True)

# --------------------------------------------------------------------------- #
# 发送器
# --------------------------------------------------------------------------- #
class Sender:
    def __init__(self, host: str, preset: dict, *, bind_port: bool, dry_run: bool):
        self.host = host
        self.preset = preset
        self.dry_run = dry_run
        self.video_sock = None
        self.control_sock = None
        self.seq = 0
        self.sent_frames = 0
        self.sent_packets = 0
        self.sent_bytes = 0
        self.pongs = 0
        self.rtt_ms = -1
        self.ping_times: dict[int, float] = {}
        self.ping_counter = 0
        self._stop = threading.Event()
        self._dumped = 0

        if dry_run:
            return
        self.video_sock = self._make_socket(5012, bind_port)
        self.control_sock = self._make_socket(5013, bind_port)

    def _make_socket(self, port: int, bind_local: bool) -> socket.socket:
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 1 << 20)
        if bind_local:
            try:
                sock.bind(("", port))
                print(f"[i] 本地 {port} 绑定成功（与原实现一致）")
            except OSError as exc:
                print(f"[!] 本地 {port} 绑定失败（{exc}），改用临时端口")
        return sock

    # ---- 控制面 ------------------------------------------------------------
    def start_heartbeat(self):
        if self.dry_run:
            return

        def loop():
            while not self._stop.wait(1.0):
                self.ping_counter = (self.ping_counter + 1) & 0xFFFFFFFF
                self.ping_times[self.ping_counter] = time.monotonic()
                if len(self.ping_times) > 32:
                    self.ping_times.pop(next(iter(self.ping_times)))
                try:
                    self.control_sock.sendto(protocol.heartbeat(self.ping_counter),
                                             (self.host, 5013))
                except OSError as exc:
                    print(f"[!] 心跳发送失败: {exc}")

        threading.Thread(target=loop, daemon=True, name="heartbeat").start()

        def listen():
            while not self._stop.is_set():
                try:
                    data, _ = self.control_sock.recvfrom(2048)
                except OSError:
                    break
                ok, counter, length = protocol.parse_pong(data)
                if ok:
                    self.pongs += 1
                    if counter is not None and counter in self.ping_times:
                        self.rtt_ms = int((time.monotonic() - self.ping_times.pop(counter)) * 1000)
                        print(f"[<] pong #{self.pongs} len={length} RTT={self.rtt_ms}ms")
                    else:
                        print(f"[<] pong #{self.pongs} len={length} {data.hex()}")

        threading.Thread(target=listen, daemon=True, name="pong").start()

    # ---- 视频面 ------------------------------------------------------------
    def send_frame(self, payload: bytes, timestamp_ms: int, keyframe: bool):
        packets, self.seq = protocol.fragment(
            payload, timestamp_ms,
            seq=self.seq, keyframe=keyframe,
            codec=self.preset["codec"], chunk=self.preset["chunk"],
        )
        self.sent_frames += 1
        for packet in packets:
            self.sent_packets += 1
            self.sent_bytes += len(packet)
            if self.dry_run:
                if self._dumped < 3:
                    print(f"    {packet[:20].hex()}  {protocol.explain_header(packet)}")
                    self._dumped += 1
                continue
            try:
                self.video_sock.sendto(packet, (self.host, 5012))
            except OSError as exc:
                print(f"[!] 视频发送失败: {exc}")
                return

    def stop(self):
        self._stop.set()
        for sock in (self.video_sock, self.control_sock):
            if sock is not None:
                sock.close()


def build_frames(args, preset: dict):
    """按来源产出 (rgb24 字节 或 JPEG 字节)。"""
    source = args.source
    if source == "test":
        index = 0
        while True:
            yield render_test_pattern(index, preset["width"], preset["height"])
            index += 1
    elif source.startswith("image:"):
        path = source.split(":", 1)[1]
        frame = load_image_frame(path, preset["width"], preset["height"])
        while True:
            yield frame
    elif source.startswith("video:"):
        path = source.split(":", 1)[1]
        yield from video_frames(path, preset["width"], preset["height"], preset["fps"])
    else:
        sys.exit(f"未知来源: {source}")


def jpeg_encode(rgb: bytes, width: int, height: int, quality: int) -> bytes:
    import io

    img = Image.frombytes("RGB", (width, height), rgb)
    buf = io.BytesIO()
    img.save(buf, format="JPEG", quality=quality)
    return buf.getvalue()


def validate_source(source: str) -> None:
    """开局就把路径问题报出来，别让它死在工作线程里。"""
    if source == "test":
        return
    if source.startswith(("image:", "video:")):
        path = source.split(":", 1)[1]
        if not os.path.exists(path):
            sys.exit(f"找不到文件: {path}")
        if source.startswith("image:"):
            try:
                Image.open(path).verify()
            except Exception as exc:  # noqa: BLE001 - 只做友好提示
                sys.exit(f"打不开图片 {path}: {exc}")
        return
    sys.exit(f"未知来源: {source}（支持 test / image:路径 / video:路径）")


def main() -> int:
    ap = argparse.ArgumentParser(description="九号仪表投屏发送端（协议逆向版）")
    ap.add_argument("--host", required=True, help="仪表 IP，例如 192.168.1.1")
    ap.add_argument("--preset", default="5in", choices=sorted(PRESETS))
    ap.add_argument("--source", default="test", help="test | image:路径 | video:路径")
    ap.add_argument("--fps", type=int, help="覆盖预设帧率")
    ap.add_argument("--bitrate", type=int, help="覆盖预设码率（kbps）")
    ap.add_argument("--gop", type=int, default=20, help="关键帧间隔（默认 20，原实现 10 偏密）")
    ap.add_argument("--quality", type=int, default=80, help="JPEG 质量（仅 4.3 寸）")
    ap.add_argument("--duration", type=float, default=0, help="运行秒数，0 表示一直跑")
    ap.add_argument("--no-bind-port", action="store_true", help="不绑定本地 5012/5013")
    ap.add_argument("--dry-run", action="store_true", help="不联网，只打印前几个包")
    args = ap.parse_args()

    validate_source(args.source)

    preset = dict(PRESETS[args.preset])
    if args.source.startswith("image:") and not args.fps:
        # 静态图没必要 20fps 重发：仪表收到新帧才刷新，每秒 2 帧足够
        preset["fps"] = 2
    if args.fps:
        preset["fps"] = args.fps
    if args.bitrate and preset["codec"] == "h264":
        preset["bitrate"] = args.bitrate
    if preset.get("note"):
        print(f"[i] 预设 {args.preset}: {preset['width']}x{preset['height']} "
              f"{preset['fps']}fps {preset['codec']} — {preset['note']}")

    sender = Sender(args.host, preset, bind_port=not args.no_bind_port, dry_run=args.dry_run)
    sender.start_heartbeat()

    stop = threading.Event()
    started = time.monotonic()
    frame_interval = 1.0 / preset["fps"]
    next_at = time.monotonic()

    try:
        if preset["codec"] == "jpeg":
            index = 0
            for rgb in build_frames(args, preset):
                if stop.is_set():
                    break
                payload = jpeg_encode(rgb, preset["width"], preset["height"], args.quality)
                ts = int(index * 1000 / preset["fps"]) & 0xFFFFFFFF
                sender.send_frame(payload, ts, keyframe=True)
                index += 1
                _pace(next_at, frame_interval)
                next_at += frame_interval
                if _expired(args, started):
                    break
        else:
            proc = spawn_encoder(preset["width"], preset["height"], preset["fps"],
                                 preset["bitrate"], args.gop)
            aus: queue.Queue = queue.Queue(maxsize=64)
            reader = threading.Thread(target=split_access_units,
                                      args=(proc.stdout, aus, stop), daemon=True)
            reader.start()

            def pump():
                interval = 1.0 / preset["fps"]
                due = time.monotonic()
                for rgb in build_frames(args, preset):
                    if stop.is_set() or proc.poll() is not None:
                        return
                    try:
                        proc.stdin.write(rgb)
                        proc.stdin.flush()
                    except (BrokenPipeError, OSError):
                        return
                    due += interval
                    delay = due - time.monotonic()
                    if delay > 0:
                        time.sleep(delay)

            threading.Thread(target=pump, daemon=True, name="pump").start()
            index = 0
            while not stop.is_set():
                if _expired(args, started):
                    break
                try:
                    au, key = aus.get(timeout=0.5)
                except queue.Empty:
                    continue
                ts = int(index * 1000 / preset["fps"]) & 0xFFFFFFFF
                sender.send_frame(au, ts, key)
                index += 1
            stop.set()
            try:
                proc.kill()
            except OSError:
                pass
    except KeyboardInterrupt:
        print("\n[i] 手动中断")
    finally:
        stop.set()
        sender.stop()
        elapsed = max(1e-6, time.monotonic() - started)
        kbps = sender.sent_bytes * 8 / elapsed / 1000
        print(f"\n[i] 结束：{sender.sent_frames} 帧 / {sender.sent_packets} 包 / "
              f"{sender.sent_bytes / 1024:.1f} KiB / {kbps:.0f} kbps / "
              f"pong {sender.pongs} 次 / 最后 RTT {sender.rtt_ms} ms")
    return 0


def _pace(next_at: float, interval: float):
    now = time.monotonic()
    if next_at > now:
        time.sleep(next_at - now)


def _expired(args, started: float) -> bool:
    return args.duration > 0 and (time.monotonic() - started) >= args.duration


if __name__ == "__main__":
    raise SystemExit(main())
