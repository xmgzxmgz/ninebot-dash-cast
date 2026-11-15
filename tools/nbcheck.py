#!/usr/bin/env python3
"""nbcheck.py —— 九号仪表投屏链路体检（只依赖标准库）。

一次跑完把四件事分开：网卡/SSID、路由（有没有被 VPN 抢走）、本地端口占用、
控制通道心跳（仪表是否真的在接收态）。

用法：
    python3 nbcheck.py                       # 默认目标 192.168.1.1
    python3 nbcheck.py --host 192.168.1.1 --seconds 10
    python3 nbcheck.py --send                # 心跳通过后，接着推 10 秒测试图

判读：
    心跳有回包 → 链路与仪表都没问题，问题在发送端（transportUnavailable 那一层）。
    心跳无回包 → 仪表不在投屏接收页 / 不在同一网段 / 被 VPN 抢了路由。
"""

from __future__ import annotations

import argparse
import os
import re
import socket
import struct
import subprocess
import sys
import time

DASH_PORTS = (5012, 5013)


# --------------------------------------------------------------------------
# 环境信息
# --------------------------------------------------------------------------
def sh(cmd: list[str], timeout: float = 8) -> str:
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout).stdout
    except (OSError, subprocess.SubprocessError):
        return ""


def interfaces() -> list[tuple[str, str, str]]:
    """返回 [(接口名, IPv4, 掩码前缀)]，只列有 IPv4 的。"""
    out = sh(["ifconfig", "-a"])
    result: list[tuple[str, str, str]] = []
    name = None
    for line in out.splitlines():
        if line and not line[0].isspace():
            name = line.split(":")[0]
        m = re.match(r"\s+inet (\d+\.\d+\.\d+\.\d+) netmask (0x[0-9a-f]+)", line)
        if m and name:
            prefix = bin(int(m.group(2), 16)).count("1")
            result.append((name, m.group(1), str(prefix)))
    return result


def wifi_ssid() -> str:
    for iface in ("en0", "en1"):
        out = sh(["networksetup", "-getairportnetwork", iface]).strip()
        m = re.search(r"Current Wi-Fi Network: (.+)$", out)
        if m:
            return f"{iface} → {m.group(1).strip()}"
    # macOS 新版 networksetup 会返回 "not associated"，退到系统信息里读
    out = sh(["system_profiler", "SPAirPortDataType"], timeout=20)
    m = re.search(r"Current Network Information:\s*\n\s*(\S.*?):\s*$", out, re.M)
    if m:
        return f"en0 → {m.group(1).strip()}"
    return "（读不到 SSID）"


def vpn_default_ifaces() -> list[str]:
    """持有默认路由（0.0.0.0/0 或 128/1 这类拆分默认路由）的 utun 接口。"""
    out = sh(["netstat", "-rn", "-f", "inet"])
    found = []
    for line in out.splitlines():
        parts = line.split()
        if len(parts) >= 4 and parts[0] in {"default", "1", "128/1"} and parts[-1].startswith("utun"):
            name = parts[-1]
            if name not in found:
                found.append(name)
    return found


def holders(port: int) -> list[str]:
    out = sh(["lsof", "-nP", f"-iUDP:{port}"])
    lines = [ln for ln in out.splitlines()[1:] if ln.strip()]
    return lines


def subnet_of(host: str, table: list[tuple[str, str, str]]) -> tuple[str, str] | None:
    """找出哪个本地接口和目标同网段。"""
    target = [int(x) for x in host.split(".")]
    best = None
    for name, ip, prefix in table:
        bits = int(prefix)
        if bits >= 32:
            continue
        mask = (0xFFFFFFFF << (32 - bits)) & 0xFFFFFFFF
        a = struct.unpack(">I", socket.inet_aton(ip))[0] & mask
        b = struct.unpack(">I", socket.inet_aton(host))[0] & mask
        if a == b and (best is None or bits > int(best[2])):
            best = (name, ip, prefix)
    return (best[0], best[1]) if best else None


# --------------------------------------------------------------------------
# 控制通道心跳
# --------------------------------------------------------------------------
def heartbeat(counter: int) -> bytes:
    buf = bytearray(20)
    buf[0], buf[1], buf[3] = 0x85, 0xCC, 0x04
    struct.pack_into("<I", buf, 12, counter & 0xFFFFFFFF)
    buf[16] = 2
    return bytes(buf)


def is_pong(data: bytes) -> bool:
    return len(data) >= 4 and data[:4] == b"\x85\xcc\x00\x04"


def probe(host: str, src_ip: str | None, local_ips: set[str], seconds: float) -> tuple[int, list[str]]:
    if host in local_ips:
        return 0, [f"目标是本机地址（{host}），心跳没有意义，跳过"]

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    bound = None
    if src_ip:
        for port in (5013, 0):
            try:
                sock.bind((src_ip, port))
                bound = f"{src_ip}:{port or '临时端口'}"
                break
            except OSError:
                continue
    sock.settimeout(0.5)
    own = sock.getsockname()

    notes: list[str] = []
    print(f"    控制 socket 绑定：{bound or '默认（未指定源地址）'}")
    ok, total, counter = 0, 0, 0
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        counter = (counter + 1) & 0xFFFFFFFF
        total += 1
        t0 = time.monotonic()
        try:
            sock.sendto(heartbeat(counter), (host, 5013))
        except OSError as exc:
            notes.append(f"[!] 发不出去：{exc}（多半是路由/网卡问题）")
            break
        try:
            data, addr = sock.recvfrom(2048)
        except socket.timeout:
            print(f"    ping #{counter}  {int((time.monotonic() - t0) * 1000)}ms  无回包")
            time.sleep(0.4)
            continue
        if addr == own:  # 本机 IP 恰好是目标时会收回自己的包
            print(f"    ping #{counter}  收回自己的包，非 pong")
            time.sleep(0.4)
            continue
        if is_pong(data):
            ok += 1
            rtt = int((time.monotonic() - t0) * 1000)
            print(f"    ping #{counter}  pong 来自 {addr[0]}  {len(data)} 字节  RTT≈{rtt}ms  {data.hex()}")
        else:
            print(f"    ping #{counter}  未知回包 来自 {addr[0]}  {len(data)} 字节  {data.hex()}")
        time.sleep(0.5)
    sock.close()
    notes.append(f"心跳 {total} 发 / {ok} 回")
    return ok, notes


# --------------------------------------------------------------------------
def main() -> int:
    ap = argparse.ArgumentParser(description="九号仪表投屏链路体检")
    ap.add_argument("--host", default="192.168.1.1")
    ap.add_argument("--seconds", type=float, default=8.0)
    ap.add_argument("--send", action="store_true", help="心跳通过后推 10 秒测试图")
    args = ap.parse_args()

    print("=" * 62)
    print(f"目标 {args.host}：视频 5012 / 控制 5013")
    print("=" * 62)

    table = interfaces()
    print("\n[1] 本机网卡")
    for name, ip, prefix in table:
        print(f"    {name:<8} {ip}/{prefix}")
    print(f"    Wi-Fi  {wifi_ssid()}")

    same = subnet_of(args.host, table)
    vpn = vpn_default_ifaces()
    print(f"\n[2] 去 {args.host} 的出口")
    if same:
        print(f"    ✓ 同网段出口 {same[0]}（本机 {same[1]}），局域网直连，路由正常")
    else:
        print("    ✗ 本机没有接口落在目标网段 —— 先连上仪表的 Wi-Fi 热点")
        if vpn:
            print(f"      另外 {', '.join(vpn)} 持有默认路由（代理 TUN / Tailscale），")
            print("      连上热点后如果出口还是 utun，先把它们关掉再试")

    print("\n[3] 本地端口占用")
    busy = False
    for port in DASH_PORTS:
        lines = holders(port)
        if lines:
            busy = True
            print(f"    ✗ {port} 已被占用：")
            for ln in lines:
                print(f"      {ln}")
        else:
            print(f"    ✓ {port} 空闲")
    if busy:
        print("      （旧进程没退干净，绑定会失败或收到别人的包，先 kill 掉）")

    print(f"\n[4] 控制通道心跳（{args.seconds:.0f} 秒）")
    ok, notes = probe(args.host, same[1] if same else None,
                      {ip for _, ip, _ in table} | {"127.0.0.1"}, args.seconds)
    for n in notes:
        print(f"    {n}")

    print("\n" + "=" * 62)
    if ok:
        print("结论：控制通道通，仪表在接收态。黑屏问题在发送端，不在链路。")
        if args.send:
            here = os.path.dirname(os.path.abspath(__file__))
            script = os.path.join(here, "ninebot_send.py")
            print(f"\n接着跑参考实现：{script} --host {args.host} --preset 5in --duration 10")
            os.execv(sys.executable, [sys.executable, script, "--host", args.host,
                                      "--preset", "5in", "--duration", "10"])
    else:
        print("结论：控制通道不通。按上面 [1][2][3] 的红叉逐条排，")
        print("      最常见的是：仪表没停在投屏接收页，或 Wi-Fi 偷偷跳回了别的热点。")
    print("=" * 62)
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
