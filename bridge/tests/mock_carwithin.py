#!/usr/bin/env python3
"""mock_carwithin.py —— 本地假 CarWithin，用来在没有 iPhone 的情况下验证链路。

它做三件事，模拟 CarWithin 0.2 的网页共享协议：
1. 在 ws://127.0.0.1:<port>/stream 上发 `hello`（含 codec 与 base64 的 avcC）；
2. 收到 `{"type":"ready"}` 后开始推帧；
3. 每帧 = 1 字节关键帧标志 + 8 字节大端时间戳 + AVCC（长度前缀 NAL）数据。

用法：
    python bridge/tests/mock_carwithin.py 8765
    python bridge/stream_bridge.py --host 127.0.0.1 \\
        --source "pipe:python bridge/carwithin_ws.py ws://127.0.0.1:8765/stream" --dry-run --duration 4
"""

from __future__ import annotations

import asyncio
import base64
import io
import struct
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "tools"))

import h264pipe  # noqa: E402


def build_reference() -> tuple[bytes, list[tuple[bytes, bool]]]:
    """用 ffmpeg 生成一段参考流，切成 AU，返回 (avcC, [(AVCC 帧, 是否关键帧)])。"""
    ffmpeg = h264pipe.ffmpeg_path()
    raw = subprocess.run(
        [ffmpeg, "-v", "error", "-f", "lavfi", "-i", "testsrc2=size=640x360:rate=15",
         "-t", "2", "-c:v", "libx264", "-profile:v", "baseline", "-preset", "ultrafast",
         "-x264-params", "aud=1:repeat-headers=1:keyint=15:min-keyint=15:scenecut=0",
         "-f", "h264", "-"],
        capture_output=True, check=True).stdout

    import queue
    import threading

    q: queue.Queue = queue.Queue()
    h264pipe.split_access_units(io.BytesIO(raw), q, threading.Event())
    frames: list[tuple[bytes, bool]] = []
    sps = b""
    pps = b""
    for au, key in list(q.queue):
        nals = [data for _, data in h264pipe._iter_nals(au)]
        for nal in h264pipe._iter_nals(au):
            if nal[0] == 7 and not sps:
                sps = nal[1]
            if nal[0] == 8 and not pps:
                pps = nal[1]
        avcc = b"".join(struct.pack(">I", len(n)) + n for n in nals)
        frames.append((avcc, key))
    if not sps or not pps:
        raise SystemExit("参考流里没有 SPS/PPS")
    cfg = bytearray([1, sps[1], sps[2], sps[3], 0xFF, 0xE1])
    cfg += struct.pack(">H", len(sps)) + sps
    cfg += bytes([1]) + struct.pack(">H", len(pps)) + pps
    return bytes(cfg), frames


async def serve(port: int) -> None:
    import websockets

    avcc, frames = build_reference()
    print(f"[i] 参考流 {len(frames)} 帧，avcC {len(avcc)} 字节", flush=True)

    async def handler(ws):
        hello = {
            "type": "hello", "page": 1, "codec": "avc1.42E01E",
            "name": "H.264", "width": 640, "height": 360,
            "description": base64.b64encode(avcc).decode(),
        }
        import json

        await ws.send(json.dumps(hello))
        ready = False
        async for message in ws:
            if isinstance(message, str) and '"ready"' in message:
                ready = True
                break
        if not ready:
            return
        started = time.monotonic()
        index = 0
        while index < len(frames) * 4:  # 循环播四遍，够 dry-run 用了
            ts = int((time.monotonic() - started) * 1_000_000)
            payload, key = frames[index % len(frames)]
            await ws.send(bytes([1 if key else 0]) + struct.pack(">Q", ts) + payload)
            index += 1
            await asyncio.sleep(1 / 15)

    async with websockets.serve(handler, "127.0.0.1", port, max_size=None):
        print(f"[i] mock CarWithin 监听 ws://127.0.0.1:{port}/stream", flush=True)
        await asyncio.Future()


if __name__ == "__main__":
    asyncio.run(serve(int(sys.argv[1]) if len(sys.argv) > 1 else 8765))
