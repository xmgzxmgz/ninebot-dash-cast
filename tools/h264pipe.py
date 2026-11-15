"""H.264 管道工具：ffmpeg 定位、编码参数、把 Annex-B 输出切成访问单元。

`ninebot_send.py` 与 `bridge/stream_bridge.py` 共用这一层，避免两边各写一份切帧逻辑。
"""

from __future__ import annotations

import os
import re
import shutil
import subprocess
import sys
import threading

AUD_PATTERNS = (b"\x00\x00\x00\x01\x09", b"\x00\x00\x01\x09")
_START_CODE = re.compile(rb"\x00\x00\x00\x01|\x00\x00\x01")


def ffmpeg_path() -> str:
    env = os.environ.get("FFMPEG")
    if env and os.path.exists(env):
        return env
    exe = shutil.which("ffmpeg")
    if exe:
        return exe
    try:
        import imageio_ffmpeg

        return imageio_ffmpeg.get_ffmpeg_exe()
    except ImportError:
        sys.exit("需要 ffmpeg：装系统 ffmpeg、设置 FFMPEG 环境变量，或 pip install imageio-ffmpeg")


def encoder_args(width: int, height: int, fps: int, bitrate: int, gop: int) -> list[str]:
    """Baseline + 无 B 帧 + 每关键帧重复 SPS/PPS，仪表只吃这一档。"""
    return [
        "-c:v", "libx264", "-profile:v", "baseline", "-pix_fmt", "yuv420p",
        "-preset", "veryfast", "-tune", "zerolatency",
        "-b:v", f"{bitrate}k", "-maxrate", f"{bitrate}k", "-bufsize", f"{bitrate * 2}k",
        "-g", str(gop),
        "-x264-params", f"aud=1:repeat-headers=1:keyint={gop}:min-keyint={gop}:scenecut=0",
        # 关键：不 flush 的话，muxer 会在 32KB 缓冲里囤着，低码率场景下几十秒才吐一坨
        "-flush_packets", "1",
        "-f", "h264", "-",
    ]


def scale_filter(width: int, height: int) -> str:
    """等比缩放 + 居中补黑边，保持宽高为偶数（VideoToolbox / x264 都挑剔）。"""
    w, h = width - width % 2, height - height % 2
    return (f"scale={w}:{h}:force_original_aspect_ratio=decrease,"
            f"pad={w}:{h}:(ow-iw)/2:(oh-ih)/2")


def spawn(cmd: list[str], *, stdin_pipe: bool = False) -> subprocess.Popen:
    return subprocess.Popen(
        cmd,
        stdin=subprocess.PIPE if stdin_pipe else subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        bufsize=0,
    )


def split_access_units(stream, out, stop: threading.Event) -> None:
    """读 stdout，按 AUD 切访问单元，带 5 号 NAL 即关键帧。

    4 字节起始码里包含 3 字节变体，两种都找但要合并，否则会把一个 AUD 切成两个空帧。
    """
    buf = bytearray()
    while not stop.is_set():
        chunk = _read_available(stream)
        if not chunk:
            break
        buf.extend(chunk)
        while True:
            cut = _next_au_end(buf)
            if cut is None:
                break
            au = bytes(buf[:cut])
            del buf[:cut]
            if has_vcl(au):
                out.put((au, has_idr(au)))
    if buf and not stop.is_set():
        au = bytes(buf)
        if has_vcl(au):
            out.put((au, has_idr(au)))


def _read_available(stream, size: int = 65536) -> bytes:
    """读"当前有多少拿多少"，不要等满 64KB。

    BufferedReader.read(n) 会阻塞到凑满 n 字节或 EOF；低码率/慢源场景下
    这会让切帧要等好几秒，表现为"一帧都不出"。优先用 os.read 拿可用字节。
    """
    fd = getattr(stream, "fileno", None)
    if fd is not None:
        try:
            return os.read(fd(), size)
        except (OSError, ValueError):
            return b""
    return stream.read(size)


def _next_au_end(buf: bytearray) -> int | None:
    """返回第一个完整访问单元的结束偏移；凑不齐一帧返回 None。

    优先用 AUD（ffmpeg 自己编码时会有）。但 adb screenrecord、安卓屏幕录制的
    裸 H.264 往往**没有 AUD**，这时按 slice 头里的 first_mb_in_slice==0 切边界。
    """
    starts = _aud_positions(buf)
    if len(starts) >= 2:
        return starts[1]
    if starts:
        return None
    starts = _slice_positions(buf)
    if len(starts) >= 2:
        return starts[1]
    return None


def _slice_positions(buf: bytearray) -> list[int]:
    """按「VCL 切片的 first_mb_in_slice == 0」找访问单元起点。

    slice 头第一个字段是 ue(v)，值为 0 时编码成单个 '1' 位，即首字节最高位为 1。
    起点要向前吞掉紧邻的 SPS/PPS/SEI/AUD，否则关键帧会丢掉参数集。
    """
    nals = _nal_list(buf)
    starts: list[int] = []
    for idx, (start, nal_type, payload_start, payload_end) in enumerate(nals):
        if nal_type not in (1, 5) or payload_start + 1 >= payload_end:
            continue
        if not (buf[payload_start + 1] & 0x80):
            continue
        first = idx
        while first - 1 >= 0 and nals[first - 1][1] in (6, 7, 8, 9):
            first -= 1
        candidate = nals[first][0]
        if not starts or candidate != starts[-1]:
            starts.append(candidate)
    return starts


def _nal_list(data: bytearray):
    matches = list(_START_CODE.finditer(data))
    nals = []
    for idx, match in enumerate(matches):
        payload_start = match.end()
        payload_end = matches[idx + 1].start() if idx + 1 < len(matches) else len(data)
        if payload_start < payload_end:
            nals.append((match.start(), data[payload_start] & 0x1F, payload_start, payload_end))
    return nals


def _aud_positions(buf: bytearray) -> list[int]:
    positions = set()
    for pat in AUD_PATTERNS:
        i = buf.find(pat)
        while i != -1:
            positions.add(i)
            i = buf.find(pat, i + 1)
    merged: list[int] = []
    for pos in sorted(positions):
        if not merged or pos - merged[-1] > 3:
            merged.append(pos)
    return merged


def _iter_nals(data: bytes):
    matches = list(_START_CODE.finditer(data))
    for idx, match in enumerate(matches):
        start = match.end()
        end = matches[idx + 1].start() if idx + 1 < len(matches) else len(data)
        if start < end:
            yield data[start] & 0x1F, data[start:end]


def has_vcl(data: bytes) -> bool:
    return any(t in (1, 5) for t, _ in _iter_nals(data))


def has_idr(data: bytes) -> bool:
    return any(t == 5 for t, _ in _iter_nals(data))
