#!/usr/bin/env python3
"""离线校验协议实现：不联网，只断言字节。

    python test_protocol.py          # 直接跑
    pytest -q test_protocol.py       # 也可以

断言依据来自 docs/PROTOCOL.md（对 ninebot_pro iOS 1.0.0 的静态逆向），
关键常量在 docs/REVERSE-NOTES.md 里都能找到对应的指令地址。
"""

from __future__ import annotations

import struct

import protocol


def test_header_basics():
    h = protocol.video_header(0x1234, 0xAABBCCDD, first=True, last=True, keyframe=True)
    assert len(h) == 20, "头部长度必须是 20"
    assert h[0] == 0x90, "byte0 = 0x90（V=2, X=1）"
    assert h[1] & 0x7F == 32, "payload type 必须固定 32"
    assert h[1] & 0x80, "末片必须置 marker 位"
    assert struct.unpack_from(">H", h, 2)[0] == 0x1234, "序列号大端"
    assert struct.unpack_from(">I", h, 4)[0] == 0xAABBCCDD, "时间戳大端、毫秒"
    assert h[15] == 1, "byte15 固定 1"
    assert h[16] == 0, "视频包 byte16 = 0（心跳包才是 2）"


def test_flags():
    single = protocol.video_header(1, 0, first=True, last=True, keyframe=True)
    assert single[17] == 0x19, f"单包关键帧应为 0x19，实际 0x{single[17]:02x}"

    first_key = protocol.video_header(1, 0, first=True, last=False, keyframe=True)
    assert first_key[17] == 0x11, "关键帧首片 = 0x10|0x01"

    mid_key = protocol.video_header(1, 0, first=False, last=False, keyframe=True)
    assert mid_key[17] == 0x01, "关键帧中间片 = 0x01"

    first_inter = protocol.video_header(1, 0, first=True, last=False, keyframe=False)
    assert first_inter[17] == 0x12, "非关键帧首片 = 0x10|0x02"

    mid_inter = protocol.video_header(1, 0, first=False, last=False, keyframe=False)
    assert mid_inter[17] == 0x02, "非关键帧中间片 = 0x02"

    last_inter = protocol.video_header(1, 0, first=False, last=True, keyframe=False)
    assert last_inter[17] == 0x0A, "非关键帧末片 = 0x08|0x02"


def test_frame_tag_is_little_endian_low10():
    h = protocol.video_header(1, 0x0000_0865, first=True, last=True, keyframe=True)
    tag = struct.unpack_from("<H", h, 18)[0]
    assert tag == 0x065, f"tag 应为时间戳低 10 位的 LE16，实际 0x{tag:03x}"
    h2 = protocol.video_header(1, 1023, first=True, last=True, keyframe=True)
    assert struct.unpack_from("<H", h2, 18)[0] == 1023
    h3 = protocol.video_header(1, 1024, first=True, last=True, keyframe=True)
    assert struct.unpack_from("<H", h3, 18)[0] == 0, "1024 应回绕到 0"


def test_h264_fragmentation():
    payload = bytes(range(256)) * 12  # 3072 字节
    packets, seq = protocol.fragment(payload, 1000, seq=0, keyframe=False, codec="h264")
    assert [len(p) for p in packets] == [1400, 1400, 332], [len(p) for p in packets]
    assert [p[17] for p in packets] == [0x12, 0x02, 0x0A]
    assert seq == 3
    assert b"".join(p[20:] for p in packets) == payload, "负载必须原样拼回"
    assert [struct.unpack_from(">H", p, 2)[0] for p in packets] == [0, 1, 2]


def test_jpeg_fragmentation():
    payload = b"\xff\xd8" + bytes(3500)
    packets, _ = protocol.fragment(payload, 5, seq=7, codec="jpeg")
    assert [len(p) for p in packets] == [1420, 1420, 722]
    assert all(p[17] == 0x01 for p in packets), "JPEG 固定 0x01"
    assert all(p[1] & 0x7F == 32 for p in packets)


def test_heartbeat_exact_bytes():
    hb = protocol.heartbeat(7)
    assert len(hb) == 20
    assert hb[:8].hex() == "85cc000400000000", "与 IPA 里 __const 的常量一致"
    assert hb[8:12] == b"\x00\x00\x00\x00"
    assert hb[12:16] == (7).to_bytes(4, "little"), "计数器小端"
    assert hb[16] == 2 and hb[17:] == b"\x00\x00\x00", "byte16 = 2，其后三个 0"


def test_parse_pong_20():
    good = bytearray(20)
    good[0], good[1], good[3] = 0x85, 0xCC, 4
    struct.pack_into("<I", good, 12, 42)
    ok, counter, length = protocol.parse_pong(bytes(good))
    assert ok and counter == 42 and length == 20


def test_parse_pong_24():
    """七寸仪表回 24 字节——官方实现硬校验 20，所以永远认不出来。"""
    good = bytearray(24)
    good[0], good[1], good[3] = 0x85, 0xCC, 4
    struct.pack_into("<I", good, 20, 99)
    ok, counter, length = protocol.parse_pong(bytes(good))
    assert ok and length == 24
    assert counter == 99


def test_parse_pong_rejects():
    ok, counter, _ = protocol.parse_pong(b"\x85\xcc\x00\x05" + bytes(16))
    assert not ok and counter is None
    ok, _, _ = protocol.parse_pong(b"\x00" * 20)
    assert not ok


def test_explain_header_runs():
    packet = protocol.video_header(3, 1000, first=True, last=True, keyframe=True) + b"x" * 10
    text = protocol.explain_header(packet)
    assert "关键帧" in text and "seq=3" in text


def test_matches_ipa_constants():
    """把逆向得到的常量逐条比对，防止以后改崩。"""
    assert protocol.HEADER_SIZE == 20
    assert protocol.PAYLOAD_TYPE == 32
    assert protocol.H264_CHUNK == 1380, "1380 + 20 = 1400，与原实现的 '20 + 1400' 对齐"
    assert protocol.JPEG_CHUNK == 1400
    assert bytes.fromhex("85cc000400000000") == protocol.heartbeat(0)[:8]


if __name__ == "__main__":
    failures = 0
    for name, fn in sorted(globals().items()):
        if name.startswith("test_") and callable(fn):
            try:
                fn()
                print(f"  ok   {name}")
            except AssertionError as exc:
                failures += 1
                print(f"  FAIL {name}: {exc}")
    print(f"\n{'全部通过' if not failures else str(failures) + ' 个失败'}")
    raise SystemExit(1 if failures else 0)
