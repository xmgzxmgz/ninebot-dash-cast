#!/usr/bin/env python3
"""carwithin_ws.py —— 把 CarWithin 的网页共享流转成 Annex-B H.264 输出到 stdout。

用途：让 bridge/stream_bridge.py 直接把 iPhone 上的真 CarPlay 推给仪表，不用开浏览器：

    python bridge/stream_bridge.py --host 192.168.1.1 \
        --source "pipe:python bridge/carwithin_ws.py ws://192.168.1.23:8080/stream"

协议依据（静态逆向 CarWithin 0.2，bundle id `local.tds.carkit`）：
- 网页端连 `ws(s)://<host>/stream`，先发 `{"type":"ready","decoder":"webcodecs"}`；
- 服务端回 `hello`，带 codec（如 avc1.42E01E）与 base64 的 description（avcC）；
- 二进制帧：[0] 关键帧标志（1=key），[1..8] 大端 64 位时间戳（微秒），[9:] 编码数据；
- 编码数据是 AVCC 格式（长度前缀 NAL），必须转成 Annex-B 才能喂 ffmpeg。

每帧前补一个 AUD：手机端裸流没有访问单元分隔符，ffmpeg 在实时管道上会判不出帧边界，
直接报 "Could not find codec parameters / unspecified size"。
"""

from __future__ import annotations

import argparse
import asyncio
import base64
import json
import struct
import sys

try:
    import websockets
except ImportError:  # pragma: no cover
    websockets = None

AUD = bytes((0, 0, 0, 1, 9, 0x10))


def parse_avcc(config: bytes) -> tuple[list[bytes], list[bytes], int]:
    """解析 avcC（AVCDecoderConfigurationRecord），返回 (SPS, PPS, NAL 长度字节数)。"""
    if len(config) < 7 or config[0] != 1:
        raise ValueError("不是合法的 avcC")
    nal_len_size = (config[4] & 0x03) + 1
    sps_count = config[5] & 0x1F
    pos = 6
    sps_list: list[bytes] = []
    for _ in range(sps_count):
        length = struct.unpack_from(">H", config, pos)[0]
        pos += 2
        sps_list.append(config[pos:pos + length])
        pos += length
    pps_count = config[pos] if pos < len(config) else 0
    pos += 1
    pps_list: list[bytes] = []
    for _ in range(pps_count):
        length = struct.unpack_from(">H", config, pos)[0]
        pos += 2
        pps_list.append(config[pos:pos + length])
        pos += length
    return sps_list, pps_list, nal_len_size


def frame_to_annexb(payload: bytes, nal_len_size: int) -> bytes:
    """长度前缀 NAL → 起始码 NAL；尾部截断的部分直接丢弃。"""
    out = bytearray()
    pos = 0
    while pos + nal_len_size <= len(payload):
        length = int.from_bytes(payload[pos:pos + nal_len_size], "big")
        pos += nal_len_size
        if length <= 0 or pos + length > len(payload):
            break
        out += b"\x00\x00\x00\x01"
        out += payload[pos:pos + length]
        pos += length
    return bytes(out)


def parameter_sets(sps_list: list[bytes], pps_list: list[bytes]) -> bytes:
    out = bytearray()
    for nal in sps_list + pps_list:
        out += b"\x00\x00\x00\x01" + nal
    return bytes(out)


async def run(url: str, *, verbose: bool) -> int:
    if websockets is None:
        sys.exit("需要 websockets：pip install websockets")
    out = sys.stdout.buffer
    sps: list[bytes] = []
    pps: list[bytes] = []
    nal_len_size = 4
    frames = 0

    async with websockets.connect(url, max_size=None, ping_interval=5) as ws:
        await ws.send('{"type":"ready","decoder":"webcodecs"}')
        if verbose:
            print(f"[i] 已连接 {url}", file=sys.stderr)

        async for message in ws:
            if isinstance(message, str):
                msg = json.loads(message)
                if msg.get("type") == "hello":
                    description = msg.get("description")
                    if description:
                        try:
                            sps, pps, nal_len_size = parse_avcc(base64.b64decode(description))
                        except ValueError as exc:
                            print(f"[!] avcC 解析失败：{exc}", file=sys.stderr)
                    if verbose:
                        print(f"[i] hello codec={msg.get('codec')} "
                              f"{msg.get('width')}x{msg.get('height')} "
                              f"SPS/PPS={len(sps)}/{len(pps)}", file=sys.stderr)
                continue

            if len(message) < 10:
                continue
            keyframe = message[0] == 1
            annexb = frame_to_annexb(message[9:], nal_len_size)
            if not annexb:
                continue
            out.write(AUD)
            if keyframe and sps:
                out.write(parameter_sets(sps, pps))
            out.write(annexb)
            out.flush()
            frames += 1
            if verbose and frames % 100 == 0:
                print(f"[i] 已转 {frames} 帧", file=sys.stderr)
    return 0


def selftest() -> int:
    """离线自检：造一个 avcC + 两个 NAL 的帧，验证转换结果。"""
    sps = bytes.fromhex("6742e01e95a81505")
    pps = bytes.fromhex("68ce3c80")
    avcc = bytearray([1, sps[1], sps[2], sps[3], 0xFF, 0xE1])
    avcc += struct.pack(">H", len(sps)) + sps
    avcc += bytes([1]) + struct.pack(">H", len(pps)) + pps

    parsed_sps, parsed_pps, nal_len = parse_avcc(bytes(avcc))
    assert parsed_sps == [sps], "SPS 解析错误"
    assert parsed_pps == [pps], "PPS 解析错误"
    assert nal_len == 4, f"NAL 长度字节数应为 4，实际 {nal_len}"

    nal_a = bytes.fromhex("654001")
    nal_b = bytes.fromhex("41e002")
    payload = struct.pack(">I", len(nal_a)) + nal_a + struct.pack(">I", len(nal_b)) + nal_b
    expected = b"\x00\x00\x00\x01" + nal_a + b"\x00\x00\x00\x01" + nal_b
    assert frame_to_annexb(payload, 4) == expected, "AVCC→Annex-B 转换不符"

    ps = parameter_sets([sps], [pps])
    assert ps.startswith(b"\x00\x00\x00\x01" + sps) and ps.endswith(b"\x00\x00\x00\x01" + pps)
    assert frame_to_annexb(payload[:-1], 4) == b"\x00\x00\x00\x01" + nal_a, "截断容错失败"
    assert AUD == b"\x00\x00\x00\x01\x09\x10"

    print("self-test 通过：avcC 解析 / AVCC→Annex-B / SPS-PPS / 截断容错 / AUD")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description="CarWithin WebSocket → Annex-B H.264")
    ap.add_argument("url", nargs="?", help="例如 ws://192.168.1.23:8080/stream")
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument("--verbose", action="store_true")
    args = ap.parse_args()

    if args.selftest:
        return selftest()
    if not args.url:
        ap.error("需要 WebSocket 地址，或 --selftest")
    try:
        return asyncio.run(run(args.url, verbose=args.verbose))
    except KeyboardInterrupt:
        return 0


if __name__ == "__main__":
    raise SystemExit(main())
