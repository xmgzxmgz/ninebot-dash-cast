#!/usr/bin/env python3
"""nbcast.py —— 九号仪表投屏一站式工具（体检 / 找车 / 等接收态 / 推流 / 出报告）。

一条命令走完整个流程，尽量让你少在车和电脑之间来回跑：

    python3 nbcast.py                  # 体检 + 自动找车 + 等接收态 + 推 12 秒测试图
    python3 nbcast.py --join           # 先自动连仪表热点（名字像 Ninebot/Segway 的开放热点）
    python3 nbcast.py --wait 120       # 最多等 120 秒，等你到车上点开「投屏接收」页
    python3 nbcast.py --send image:nav.png --seconds 30
    python3 nbcast.py --send video:demo.mp4
    python3 nbcast.py --send desktop   # 电脑桌面镜像（macOS 要授权屏幕录制）
    python3 nbcast.py --try-presets    # 5 寸 / 4.3 寸各推 8 秒，试哪个能出画面
    python3 nbcast.py --diag-only      # 只体检，不推流
    python3 nbcast.py --scan           # 只扫网段，找哪台回 pong
    python3 nbcast.py --self-test      # 离线自检（协议打包 + 编码器 + 抓屏能力）
    python3 nbcast.py --kill           # 清掉占着 5012/5013 的旧进程
    python3 nbcast.py --report out.md  # 全程输出另存一份，方便贴给我看

依赖：本目录的 ninebot_send.py / protocol.py / h264pipe.py（已随附），
外加 Pillow 与 ffmpeg。只有标准库做流程控制。
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import signal
import socket
import subprocess
import sys
import threading
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
SEND_PY = HERE / "ninebot_send.py"
BRIDGE_PY = HERE / "bridge" / "stream_bridge.py"
if not BRIDGE_PY.exists():                      # 放进仓库的 tools/ 时，bridge 在上一层
    BRIDGE_PY = HERE.parent / "bridge" / "stream_bridge.py"
SCREEN_PY = HERE / "screen_cast.py"
TEST_PY = HERE / "test_protocol.py"
STATE = HERE / ".nbstate.json"

sys.path.insert(0, str(HERE))
import nbcheck  # noqa: E402  复用网卡/路由/心跳这些探测函数

PRESETS = ("5in", "4.3in")
HOTSPOT_HINTS = re.compile(r"ninebot|segway|九号|kz\d|ninebot_", re.I)


# ---------------------------------------------------------------------------
# 输出（同时收集到 report）
# ---------------------------------------------------------------------------
class Log:
    def __init__(self) -> None:
        self.lines: list[str] = []

    def __call__(self, msg: str = "") -> None:
        print(msg)
        self.lines.append(msg)

    def banner(self, text: str) -> None:
        self("")
        self("─" * 58)
        self(text)

    def dump(self, path: Path, header: dict) -> None:
        body = ["# ninebot-dash-cast 诊断报告", ""]
        body += [f"- {k}: {v}" for k, v in header.items()]
        body += ["", "```", *self.lines, "```", ""]
        path.write_text("\n".join(body), encoding="utf-8")
        self(f"\n[i] 报告已写入 {path}")


log = Log()


# ---------------------------------------------------------------------------
# 状态记忆
# ---------------------------------------------------------------------------
def load_state() -> dict:
    try:
        return json.loads(STATE.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}


def save_state(**kw) -> None:
    data = load_state()
    data.update(kw)
    data["updated"] = time.strftime("%Y-%m-%d %H:%M:%S")
    try:
        STATE.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")
    except OSError:
        pass


# ---------------------------------------------------------------------------
# 网络探测
# ---------------------------------------------------------------------------
def ping_once(host: str, timeout: float = 0.6) -> bool:
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.settimeout(timeout)
    try:
        sock.sendto(nbcheck.heartbeat(1), (host, 5013))
        data, addr = sock.recvfrom(1024)
        return nbcheck.is_pong(data) and addr[0] == host
    except OSError:
        return False
    finally:
        sock.close()


def scan_subnet(local_ip: str, prefix: int, timeout: float = 0.3) -> list[str]:
    """并发扫本网段的 5013，返回回 pong 的地址。"""
    if prefix >= 31:
        return []
    block = local_ip.rsplit(".", 1)[0]
    hosts = [f"{block}.{i}" for i in range(1, 255) if f"{block}.{i}" != local_ip]
    found: list[str] = []
    lock = threading.Lock()
    queue = list(hosts)

    def worker() -> None:
        while True:
            with lock:
                if not queue:
                    return
                host = queue.pop()
            if ping_once(host, timeout):
                with lock:
                    found.append(host)

    threads = [threading.Thread(target=worker, daemon=True) for _ in range(48)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    return sorted(found, key=lambda ip: int(ip.rsplit(".", 1)[1]))


def wifi_candidates() -> list[str]:
    """系统里那些像仪表热点的网络名。"""
    out = nbcheck.sh(["system_profiler", "SPAirPortDataType"], timeout=25)
    names = re.findall(r"^\s{10,}(\S.*?):\s*$", out, re.M)
    seen, result = set(), []
    for name in names:
        name = name.strip()
        if name in seen or not HOTSPOT_HINTS.search(name):
            continue
        seen.add(name)
        result.append(name)
    return result


def join_hotspot(wanted: str | None) -> bool:
    if sys.platform != "darwin":
        log("[!] 自动连热点只实现了 macOS，其他系统请手动连")
        return False
    targets = [wanted] if wanted else wifi_candidates()
    if not targets:
        log("[!] 没扫到名字像 Ninebot/Segway 的热点，先把车通电、到仪表上把投屏热点打开")
        return False
    for ssid in targets:
        log(f"[>] 尝试连接热点：{ssid}")
        out = nbcheck.sh(["networksetup", "-setairportnetwork", "en0", ssid], timeout=25)
        if "could not find" in out.lower() or "failed" in out.lower() or "错误" in out:
            log(f"[!] 连不上：{out.strip()[:120]}")
            continue
        for _ in range(20):
            time.sleep(0.5)
            if any(ip.startswith(("192.168.", "10.", "172.")) for _, ip, _ in nbcheck.interfaces()):
                log(f"[✓] 已连上 {ssid}")
                save_state(ssid=ssid)
                return True
        log("[!] 连上了但没拿到 IP，可能热点需要密码，手动连一下")
    return False


# ---------------------------------------------------------------------------
# 体检
# ---------------------------------------------------------------------------
def diag(host: str) -> dict:
    table = nbcheck.interfaces()
    same = nbcheck.subnet_of(host, table)
    vpn = nbcheck.vpn_default_ifaces()

    log.banner("[1] 本机网络")
    for name, ip, prefix in table:
        log(f"    {name:<8} {ip}/{prefix}")
    log(f"    Wi-Fi   {nbcheck.wifi_ssid()}")

    log.banner("[2] 去仪表的出口")
    if same:
        log(f"    ✓ {same[0]} 上有 {same[1]}，与 {host} 同网段，直连没问题")
    else:
        log(f"    ✗ 没有接口落在 {host} 的网段 —— 还没连上仪表热点")
        if vpn:
            log(f"      注意 {', '.join(vpn)} 持有默认路由（代理 TUN / Tailscale），连上热点后要确认出口不是 utun")
        hotspot = wifi_candidates()
        if hotspot:
            log(f"      扫到像仪表热点的网络：{', '.join(hotspot[:4])}（可以试 --join）")

    log.banner("[3] 端口占用")
    busy = []
    for port in (5012, 5013):
        lines = nbcheck.holders(port)
        if lines:
            busy.append(port)
            log(f"    ✗ {port} 被占：")
            for ln in lines[:3]:
                log(f"      {ln}")
        else:
            log(f"    ✓ {port} 空闲")

    log.banner("[4] 仪表在线情况")
    alive = ping_once(host, 0.8)
    if alive:
        log(f"    ✓ {host}:5013 回 pong，仪表在接收态")
    else:
        log(f"    ✗ {host} 没回 pong")

    # 能力检查
    log.banner("[5] 本机能力")
    ffmpeg = "ffmpeg" if subprocess.run(["which", "ffmpeg"], capture_output=True).returncode == 0 else None
    log(f"    {'✓' if ffmpeg else '✗'} ffmpeg  {'已安装' if ffmpeg else '缺，装一下：brew install ffmpeg'}")
    try:
        import PIL  # noqa: F401
        log("    ✓ Pillow  已安装")
    except ImportError:
        log("    ✗ Pillow  缺，装一下：pip3 install pillow")
    log(f"    {'✓' if SEND_PY.exists() else '✗'} 发送端   {SEND_PY.name}")
    log(f"    {'✓' if BRIDGE_PY.exists() else '✗'} 桥接器   {BRIDGE_PY.name}")

    return {"table": table, "same": same, "busy": busy, "vpn": vpn, "alive": alive, "host": host}


# ---------------------------------------------------------------------------
# 找车
# ---------------------------------------------------------------------------
def discover(host: str | None, allow_scan: bool, timeout: float) -> str | None:
    if host:
        if ping_once(host, 1.0):
            log(f"[✓] {host} 回 pong")
            return host
        log(f"[!] {host} 没回 pong，继续找别的地址")

    saved = load_state().get("host")
    if saved and saved != host and ping_once(saved, 0.6):
        log(f"[✓] 上次用过的 {saved} 还在线")
        return saved

    table = nbcheck.interfaces()
    for candidate in ("192.168.1.1", "192.168.169.1", "192.168.0.1"):
        same = nbcheck.subnet_of(candidate, table)
        if same and ping_once(candidate, 0.6):
            log(f"[✓] {candidate} 回 pong")
            return candidate

    if not allow_scan:
        return None
    for name, ip, prefix in table:
        if ip.startswith(("127.", "169.254.")) or name.startswith(("utun", "llw", "awdl")):
            continue
        log(f"[>] 扫 {ip.rsplit('.', 1)[0]}.0/{prefix}（{name}）…")
        for hit in scan_subnet(ip, int(prefix)):
            log(f"[✓] {hit} 回 pong")
            return hit
    return None


def wait_for(want: str | None, seconds: float, allow_scan: bool) -> str | None:
    """等仪表进接收态。返回找到的 IP。"""
    deadline = time.monotonic() + seconds
    round_no = 0
    while True:
        round_no += 1
        want = discover(want, allow_scan and round_no > 1, 0)
        if want:
            return want
        if time.monotonic() >= deadline:
            return None
        left = int(deadline - time.monotonic())
        log(f"[.] 还没回 pong，{left}s 后重试（现在去仪表上点开「投屏接收」页）")
        time.sleep(min(3, max(1, left)))


# ---------------------------------------------------------------------------
# 推流
# ---------------------------------------------------------------------------
def pick_script(source: str) -> Path:
    if source in {"screen"}:
        return SCREEN_PY
    if source == "desktop" and sys.platform == "darwin":
        # avfoundation 要私有屏幕录制授权，很多环境直接不可用；screencapture 稳得多
        return SCREEN_PY
    if source in {"test"} or source.startswith(("image:", "video:")):
        return SEND_PY
    return BRIDGE_PY


def build_cmd(script: Path, host: str, preset: str, source: str,
              seconds: float, fps: int | None) -> list[str]:
    if script == SCREEN_PY:
        cmd = [sys.executable, str(script), "--host", host, "--preset", preset,
               "--duration", str(seconds)]
        if fps:
            cmd += ["--fps", str(fps)]
        if source.startswith("region:"):
            cmd += ["--region", source.split(":", 1)[1]]
        return cmd
    cmd = [sys.executable, str(script), "--host", host, "--preset", preset,
           "--source", source, "--duration", str(seconds)]
    if fps:
        cmd += ["--fps", str(fps)]
    return cmd


def send_one(host: str, preset: str, source: str, seconds: float, fps: int | None) -> tuple[int, str]:
    script = pick_script(source)
    if not script.exists():
        log(f"[!] 缺 {script}")
        return 2, ""

    cmd = build_cmd(script, host, preset, source, seconds, fps)

    log.banner(f"推流：{source} → {host} / {preset} / {seconds:.0f}s")
    log("    " + " ".join(cmd[1:]))

    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            text=True, bufsize=1, cwd=str(HERE))
    try:
        output, _ = proc.communicate(timeout=seconds + 20)
    except subprocess.TimeoutExpired:
        proc.kill()
        output, _ = proc.communicate()
        output = (output or "") + "\n[!] 超时，强制结束"
    code = proc.returncode or 0

    tail = output or ""
    for line in tail.splitlines():
        if line.strip():
            log("    " + line.rstrip())

    m = re.search(r"结束：(\d+) 帧 / (\d+) 包", tail)
    if m and m.group(2) == "0":
        log("[!] 一个包都没发出去 —— 不是仪表的问题，是本机发送路径没起来")
    return code, tail


def watchdog(stop: threading.Event, host: str, seconds: float) -> None:
    """推流期间盯着网卡，热点掉线立刻叫。"""
    table = nbcheck.interfaces()
    base_ip = nbcheck.subnet_of(host, table)
    last = base_ip[1] if base_ip else None
    t0 = time.monotonic()
    while not stop.wait(3):
        now = nbcheck.subnet_of(host, nbcheck.interfaces())
        now_ip = now[1] if now else None
        if last and now_ip != last:
            log(f"[!] 网卡变了：{last} → {now_ip or '没有同网段地址'}，热点掉了")
            last = now_ip
        left = seconds - (time.monotonic() - t0)
        if left > 3:
            log(f"[.] 还在推，剩 {left:.0f}s…")


def run(host: str, preset: str, source: str, seconds: float, fps: int | None) -> tuple[int, str]:
    stop = threading.Event()
    dog = threading.Thread(target=watchdog, args=(stop, host, seconds), daemon=True)
    dog.start()
    try:
        return send_one(host, preset, source, seconds, fps)
    finally:
        stop.set()


# ---------------------------------------------------------------------------
# 杂项动作
# ---------------------------------------------------------------------------
def kill_ports() -> None:
    killed = 0
    for port in (5012, 5013):
        for line in nbcheck.holders(port):
            parts = line.split()
            if len(parts) < 2 or not parts[0].lower().startswith(("python", "ffmpeg", "ninebot")):
                log(f"[!] {port} 的占用者看着不像我们的进程，跳过：{line.strip()[:100]}")
                continue
            pid = parts[1]
            try:
                os.kill(int(pid), signal.SIGTERM)
                killed += 1
                log(f"[✓] 已结束 {pid}（{port}）")
            except OSError as exc:
                log(f"[!] 结束 {pid} 失败：{exc}")
    if not killed:
        log("[i] 没有需要清理的进程")


def _frames(tail: str) -> int:
    m = re.search(r"结束：\s*(\d+)\s*帧", tail)
    return int(m.group(1)) if m else -1


def _run_quiet(cmd: list[str], timeout: float) -> tuple[int, str]:
    """跑一个子进程并收走输出；超时就杀掉，不抛异常。"""
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            text=True, cwd=str(HERE))
    try:
        out, _ = proc.communicate(timeout=timeout)
        return proc.returncode, out or ""
    except subprocess.TimeoutExpired:
        proc.kill()
        try:
            out, _ = proc.communicate(timeout=5)
        except subprocess.TimeoutExpired:
            out = ""
        return -9, (out or "") + "\n（超时被杀）"


def capture_probe() -> tuple[bool, str]:
    """直接问 ffmpeg 要一帧桌面，失败时把它的话原样带回来。"""
    ff = shutil.which("ffmpeg") or "ffmpeg"
    idx = 1
    out = nbcheck.sh([ff, "-hide_banner", "-f", "avfoundation", "-list_devices", "true", "-i", ""], timeout=15)
    for line in out.splitlines():
        m = re.search(r"\[(\d+)\]\s+Capture screen", line)
        if m:
            idx = int(m.group(1))
            break
    cmd = [ff, "-hide_banner", "-f", "avfoundation", "-framerate", "10",
           "-i", f"{idx}:none", "-frames:v", "1", "-f", "null", "-"]
    code, out = _run_quiet(cmd, 15)
    text = " ".join(line.strip() for line in out.splitlines() if line.strip())
    good = code == 0 and "frame" in out.lower()
    return good, (text[-400:] or f"退出码 {code}，没有输出")


def self_test(check_capture: bool = False) -> int:
    ok = True
    log.banner("自检 1/3：协议打包")
    if TEST_PY.exists():
        code, out = _run_quiet([sys.executable, str(TEST_PY)], 60)
        ok = ok and code == 0
        log(f"    {'✓' if code == 0 else '✗'} test_protocol.py 退出码 {code}")
    else:
        log("    ✗ 缺 test_protocol.py")
        ok = False

    log.banner("自检 2/3：编码器 + 打包（不发包）")
    code, out = _run_quiet([sys.executable, str(SEND_PY), "--host", "127.0.0.1",
                            "--preset", "5in", "--dry-run", "--duration", "2"], 60)
    frames = _frames(out)
    good = code == 0 and frames > 0
    ok = ok and good
    last = out.strip().splitlines()[-1] if out.strip() else "无输出"
    log(f"    {'✓' if good else '✗'} dry-run 编码 {frames if frames >= 0 else '?'} 帧：{last}")

    log.banner("自检 3/3：抓屏能力（macOS 需要屏幕录制授权）")
    if sys.platform != "darwin":
        log("    - 非 macOS，跳过")
    elif not check_capture:
        log("    - 跳过（加 --check-capture 验证；只有镜像桌面才需要）")
    else:
        good, detail = capture_probe()
        log(f"    {'✓' if good else '✗'} 桌面抓一帧：{detail}")
        if not good:
            log("      九成是没给屏幕录制权限：系统设置 → 隐私与安全性 → 屏幕录制 →")
            log("      勾上终端（或 iTerm），再完全退出终端重开")
            log("      没权限也不影响推图片/视频：--send video:demo.mp4")

    log("")
    log("自检通过，可以连车了" if ok else "自检有问题，先把上面 ✗ 的修掉")
    return 0 if ok else 1


# ---------------------------------------------------------------------------
def main() -> int:
    ap = argparse.ArgumentParser(description="九号仪表投屏一站式工具", formatter_class=argparse.RawDescriptionHelpFormatter,
                                 epilog=__doc__)
    ap.add_argument("--host", help="仪表 IP；不给就自动找")
    ap.add_argument("--send", default="test", help="test | image:路径 | video:路径 | desktop | region:x,y,w,h | 流地址")
    ap.add_argument("--preset", default="auto", choices=("auto", *PRESETS))
    ap.add_argument("--seconds", type=float, default=12, help="单次推流时长（默认 12s）")
    ap.add_argument("--fps", type=int)
    ap.add_argument("--wait", type=float, default=25, help="等仪表进接收态的最长秒数，0 表示不等")
    ap.add_argument("--diag-only", action="store_true")
    ap.add_argument("--scan", action="store_true", help="只扫网段找车")
    ap.add_argument("--try-presets", action="store_true", help="5 寸 / 4.3 寸轮流各推 8 秒")
    ap.add_argument("--loop", action="store_true", help="推完自动再来一轮（断线自动重连）")
    ap.add_argument("--join", nargs="?", const="", metavar="SSID", help="先连仪表热点；不给 SSID 就自动找")
    ap.add_argument("--kill", action="store_true", help="清掉占 5012/5013 的旧进程")
    ap.add_argument("--self-test", action="store_true")
    ap.add_argument("--check-capture", action="store_true", help="自检时顺带验一次抓屏（要屏幕录制权限）")
    ap.add_argument("--no-scan", action="store_true", help="不扫网段，只试常见网关")
    ap.add_argument("--report", help="把输出另存为 markdown")
    args = ap.parse_args()

    started = time.strftime("%Y-%m-%d %H:%M:%S")
    if args.kill:
        kill_ports()
    if args.self_test:
        code = self_test(args.check_capture)
        if args.report:
            log.dump(Path(args.report), {"时间": started, "模式": "self-test"})
        return code

    if args.join is not None:
        join_hotspot(args.join or None)

    host = args.host or "192.168.1.1"
    info = diag(host)
    if args.diag_only:
        if args.report:
            log.dump(Path(args.report), {"时间": started, "模式": "diag-only"})
        return 0

    if args.scan:
        log.banner("扫网段")
        found = []
        for name, ip, prefix in info["table"]:
            if ip.startswith(("127.", "169.254.")) or name.startswith(("utun", "llw", "awdl")):
                continue
            found += scan_subnet(ip, int(prefix))
        if found:
            log(f"[✓] 回 pong 的地址：{', '.join(found)}")
            save_state(host=found[0])
        else:
            log("[!] 这个网段没有仪表")
        if args.report:
            log.dump(Path(args.report), {"时间": started, "模式": "scan"})
        return 0 if found else 1

    preset = args.preset
    if preset == "auto":
        preset = load_state().get("preset") or "5in"
        log(f"[i] 用上次成功的预设（没有就用 5 寸）：{preset}")

    rounds = 0
    while True:
        rounds += 1
        if rounds > 1:
            log(f"\n===== 第 {rounds} 轮 =====")
        found = wait_for(args.host, max(0.0, args.wait), not args.no_scan)
        if not found:
            log.banner("打住")
            log("等不到 pong。按这个顺序查：")
            log("  1. 仪表是否停在「投屏 / 接收」页（离开这页它就把 socket 关了）")
            log("  2. Wi-Fi 是否还连着仪表热点（别被手机热点抢回去）")
            log("  3. 车里是否通电、热点是否开着")
            if args.report:
                log.dump(Path(args.report), {"时间": started, "模式": "cast", "结果": "no-pong"})
            return 1

        save_state(host=found)
        if found != host:
            log(f"[i] 实际连的是 {found}（体检时先按 {host} 探的，日志里那条 ✗ 可以忽略）")

        if args.try_presets:
            for p in PRESETS:
                run(found, p, args.send, min(8, args.seconds), args.fps)
                time.sleep(1)
                log(f"[i] {p} 推完了 —— 仪表上有画面就说明这个预设对，记下来用 --preset {p}")
            if args.report:
                log.dump(Path(args.report), {"时间": started, "模式": "try-presets", "host": found})
            return 0

        code, _ = run(found, preset, args.send, args.seconds, args.fps)
        save_state(host=found, preset=preset)

        if not args.loop:
            if args.report:
                log.dump(Path(args.report), {"时间": started, "模式": "cast", "host": found, "preset": preset})
            if code == 0:
                log.banner("推进去了")
                log("仪表上应该有画面了。没画面的话：")
                log("  · 换预设再试：--try-presets")
                log("  · 换来源：--send image:nav.png / --send desktop")
                log("  · 抓报告给我：--report cast.md")
            return code
        log("[i] 5 秒后重来（Ctrl-C 停）")
        time.sleep(5)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        print("\n[i] 手动中断")
