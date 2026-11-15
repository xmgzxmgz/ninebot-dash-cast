#!/usr/bin/env python3
"""ninebot_probe.py —— 探测仪表是否在线、是否认这条控制通道。

作用：
1. 每 0.5s 往 5013 发一个 20 字节心跳，打印回包原文与 RTT；
2. 兼容 20 字节与 24 字节回包（官方实现硬校验 20，七寸的 24 字节因此永远匹配不上）；
3. `--brute` 模式下扫描 192.168.1.0/24 的 5013，找仪表 IP。

用法：
    python ninebot_probe.py --host 192.168.1.1
    python ninebot_probe.py --brute
"""

from __future__ import annotations

import argparse
import socket

import time

import protocol


def probe(host: str, seconds: float, interval: float, bind_port: bool) -> int:
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.settimeout(interval)
    if bind_port:
        try:
            sock.bind(("", 5013))
        except OSError as exc:
            print(f"[!] 本地 5013 被占用（{exc}），改用临时端口")

    counter = 0
    sent_at: dict[int, float] = {}
    pongs = 0
    deadline = time.monotonic() + seconds if seconds > 0 else None
    print(f"[i] 探测 {host}:5013，间隔 {interval}s")

    while deadline is None or time.monotonic() < deadline:
        counter = (counter + 1) & 0xFFFFFFFF
        sent_at[counter] = time.monotonic()
        payload = protocol.heartbeat(counter)
        try:
            sock.sendto(payload, (host, 5013))
        except OSError as exc:
            print(f"[!] 发送失败: {exc}")
            return 1
        print(f"[>] ping #{counter}  {payload.hex()}")
        try:
            data, addr = sock.recvfrom(2048)
        except socket.timeout:
            print("[.] 无回包")
            continue
        ok, value, length = protocol.parse_pong(data)
        if ok:
            pongs += 1
            rtt = int((time.monotonic() - sent_at.get(value or counter, time.monotonic())) * 1000)
            print(f"[<] pong len={length} 地址={addr[0]} RTT≈{rtt}ms  {data.hex()}")
        else:
            print(f"[?] 未知回包 len={length} 地址={addr[0]}  {data.hex()}")
        time.sleep(interval)

    print(f"[i] 共收到 {pongs} 个 pong")
    return 0 if pongs else 2


def brute(seconds: float = 1.0) -> int:
    """对 192.168.1.0/24 的 5013 广播心跳，谁回 pong 就是仪表。"""
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.settimeout(seconds)
    print("[i] 扫描 192.168.1.1-254:5013")
    for last in range(1, 255):
        host = f"192.168.1.{last}"
        try:
            sock.sendto(protocol.heartbeat(1), (host, 5013))
        except OSError:
            continue
    found = []
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        try:
            data, addr = sock.recvfrom(2048)
        except socket.timeout:
            break
        ok, _, length = protocol.parse_pong(data)
        if ok:
            found.append((addr[0], length, data.hex()))
            print(f"[+] 命中 {addr[0]} len={length} {data.hex()}")
    if not found:
        print("[.] 没扫到。确认已连仪表热点、仪表已进入投屏接收态")
        return 2
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description="九号仪表控制通道探测")
    ap.add_argument("--host", help="仪表 IP")
    ap.add_argument("--seconds", type=float, default=10, help="探测时长，0 表示一直跑")
    ap.add_argument("--interval", type=float, default=0.5, help="心跳间隔秒")
    ap.add_argument("--no-bind-port", action="store_true", help="不绑定本地 5013")
    ap.add_argument("--brute", action="store_true", help="扫描 192.168.1.0/24")
    args = ap.parse_args()

    if args.brute:
        return brute()
    if not args.host:
        ap.error("需要 --host 或 --brute")
    return probe(args.host, args.seconds, args.interval, not args.no_bind_port)


if __name__ == "__main__":
    raise SystemExit(main())
