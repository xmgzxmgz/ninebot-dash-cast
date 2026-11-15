"""九号电动车仪表投屏协议 —— 按逆向规格实现的打包层。

协议来源：对 xmz28/ninebot_pro iOS 1.0.0 (com.hanlin.ninebotpro) 的静态逆向，
逐字节规格见 docs/PROTOCOL.md，证据地址见 docs/REVERSE-NOTES.md。

所有函数都是纯函数，不碰网络，方便单元测试。
"""

from __future__ import annotations

import struct

HEADER_SIZE = 20
PAYLOAD_TYPE = 32

# H.264：每片载荷 1380，加 20 字节头正好 1400（原始实现里的 "20 + 1400" 日志）
H264_CHUNK = 1380
# JPEG（4.3 寸）：每片载荷 1400，整包 1420
JPEG_CHUNK = 1400

FLAG_FIRST = 0x10
FLAG_LAST = 0x08
FLAG_KEYFRAME = 0x01
FLAG_INTER = 0x02

HEARTBEAT_LEN = 20


def video_header(
    seq: int,
    timestamp_ms: int,
    *,
    first: bool,
    last: bool,
    keyframe: bool,
    ssrc: int = 0,
    codec: str = "h264",
) -> bytes:
    """构造 20 字节视频包头。

    偏移 / 含义：
      0      0x90     V=2, X=1（声明扩展头）
      1      PT|M     32 = payload type，末片置 marker
      2..3   seq      BE16
      4..7   ts       BE32，单位毫秒
      8..11  ssrc     BE32（H.264 官方实现恒 0）
      12..14 0
      15     1        固定值
      16     0        视频包为 0（心跳包为 2）
      17     flags    0x10 首片 / 0x08 末片 / 0x01 关键帧 / 0x02 非关键帧
      18..19 tag      LE16，取时间戳低 10 位
    """
    buf = bytearray(HEADER_SIZE)
    buf[0] = 0x90
    buf[1] = PAYLOAD_TYPE | (0x80 if last else 0x00)
    struct.pack_into(">H", buf, 2, seq & 0xFFFF)
    struct.pack_into(">I", buf, 4, timestamp_ms & 0xFFFFFFFF)
    struct.pack_into(">I", buf, 8, ssrc & 0xFFFFFFFF)
    buf[15] = 1
    if codec == "h264":
        flags = 0
        if first:
            flags |= FLAG_FIRST
        if last:
            flags |= FLAG_LAST
        flags |= FLAG_KEYFRAME if keyframe else FLAG_INTER
        buf[17] = flags
    else:
        # JPEG 每帧都是独立完整图，官方实现固定写 0x01
        buf[17] = FLAG_KEYFRAME
    struct.pack_into("<H", buf, 18, timestamp_ms & 0x3FF)
    return bytes(buf)


def fragment(
    payload: bytes,
    timestamp_ms: int,
    *,
    seq: int = 0,
    keyframe: bool = False,
    codec: str = "h264",
    chunk: int | None = None,
    ssrc: int = 0,
) -> tuple[list[bytes], int]:
    """把一帧（Annex-B 或 JPEG）切成若干 RTP 包。

    返回 (包列表, 下一个序列号)。分片按字节切，不按 NALU 对齐——与原实现一致。
    """
    if chunk is None:
        chunk = H264_CHUNK if codec == "h264" else JPEG_CHUNK
    packets: list[bytes] = []
    total = len(payload)
    if total == 0:
        return packets, seq

    offset = 0
    while offset < total:
        length = min(chunk, total - offset)
        first = offset == 0
        last = offset + length >= total
        packets.append(
            video_header(
                seq,
                timestamp_ms,
                first=first,
                last=last,
                keyframe=keyframe,
                ssrc=ssrc,
                codec=codec,
            )
            + payload[offset : offset + length]
        )
        seq = (seq + 1) & 0xFFFF
        offset += length
    return packets, seq


def heartbeat(counter: int) -> bytes:
    """5013 上的 20 字节保活包。

    85 CC 00 04 | 8 字节 0 | counter(LE32) | 02 00 00 00
    """
    buf = bytearray(HEARTBEAT_LEN)
    buf[0] = 0x85
    buf[1] = 0xCC
    buf[3] = 4
    struct.pack_into("<I", buf, 12, counter & 0xFFFFFFFF)
    buf[16] = 2
    return bytes(buf)


def parse_pong(data: bytes) -> tuple[bool, int | None, int]:
    """解析仪表回包，返回 (是否 pong, 计数器, 实际长度)。

    官方实现只认长度 == 20，七寸仪表的 24 字节回包因此永远匹配不上；
    这里放宽为「长度 >= 4 且头是 85 CC 00 04」，计数器两处都试。
    """
    n = len(data)
    if n < 4:
        return False, None, n
    if data[0] != 0x85 or data[1] != 0xCC or data[2] != 0x00 or data[3] != 0x04:
        return False, None, n
    counter = None
    if n >= 16:
        value = struct.unpack_from("<I", data, 12)[0]
        if value:
            counter = value
    if counter is None and n >= 24:
        value = struct.unpack_from("<I", data, 20)[0]
        if value:
            counter = value
    return True, counter, n


def explain_header(packet: bytes) -> str:
    """把包头翻译成人话，用于 dry-run 与抓包核对。"""
    if len(packet) < HEADER_SIZE:
        return f"<{len(packet)} 字节，不足一个头>"
    seq = struct.unpack_from(">H", packet, 2)[0]
    ts = struct.unpack_from(">I", packet, 4)[0]
    ssrc = struct.unpack_from(">I", packet, 8)[0]
    flags = packet[17]
    tag = struct.unpack_from("<H", packet, 18)[0]
    parts = [f"seq={seq}", f"ts={ts}ms", f"len={len(packet)}", f"pt={packet[1] & 0x7F}"]
    if packet[1] & 0x80:
        parts.append("marker")
    labels = []
    if flags & FLAG_FIRST:
        labels.append("首片")
    if flags & FLAG_LAST:
        labels.append("末片")
    if flags & FLAG_KEYFRAME:
        labels.append("关键帧")
    elif flags & FLAG_INTER:
        labels.append("非关键帧")
    parts.append("flags=0x%02x(%s)" % (flags, "/".join(labels) or "无"))
    parts.append(f"tag={tag}")
    if ssrc:
        parts.append(f"ssrc=0x{ssrc:08x}")
    return " ".join(parts)
