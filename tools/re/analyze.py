#!/usr/bin/env python3
"""analyze.py —— 复现本项目逆向结论的最小工具集（Mach-O + ARM64）。

用法：
    # 二进制从 IPA 里解出来
    unzip NinebotPro.ipa -d ipa
    BIN=ipa/Payload/NinebotPro.app/NinebotPro

    python analyze.py info   "$BIN"                  # 段表、依赖库、符号数量
    python analyze.py syms   "$BIN" Packetizer       # 按关键字找符号地址
    python analyze.py disasm "$BIN" 0x10002ba18 260  # 反汇编指定函数
    python analyze.py scan   "$BIN"                  # 扫端口/分片等关键常量

依赖：pip install capstone
符号表未剥离时（本项目分析的版本即是），可以直接按符号名定位函数，不需要 FLIRT/signature。
"""

from __future__ import annotations

import bisect
import struct
import sys

try:
    from capstone import CS_ARCH_ARM64, CS_MODE_ARM, Cs
except ImportError:  # pragma: no cover
    Cs = None


class MachO:
    def __init__(self, path: str):
        self.data = open(path, "rb").read()
        d = self.data
        if d[:4] != b"\xcf\xfa\xed\xfe":
            raise SystemExit("只支持 64 位小端 Mach-O（magic cffaedfe）")
        (self.cputype, self.cpusub, self.filetype,
         self.ncmds, self.sizeofcmds, self.flags) = struct.unpack("<iiIIII", d[4:28])
        self.sections: list[dict] = []
        self.dylibs: list[str] = []
        self._symtab = None
        self._funcstarts = None
        self._parse()

    def _parse(self):
        d, off = self.data, 32
        for _ in range(self.ncmds):
            cmd, cmdsize = struct.unpack("<II", d[off:off + 8])
            if cmd == 0x19:
                nsects = struct.unpack("<I", d[off + 64:off + 68])[0]
                s = off + 72
                for _ in range(nsects):
                    self.sections.append(dict(
                        seg=d[s + 16:s + 32].split(b"\0")[0].decode(),
                        name=d[s:s + 16].split(b"\0")[0].decode(),
                        addr=struct.unpack("<Q", d[s + 32:s + 40])[0],
                        size=struct.unpack("<Q", d[s + 40:s + 48])[0],
                        offset=struct.unpack("<I", d[s + 48:s + 52])[0],
                    ))
                    s += 80
            elif cmd == 0x2:
                symoff, nsyms, stroff, strsize = struct.unpack("<IIII", d[off + 8:off + 24])
                self._symtab = (symoff, nsyms, stroff, strsize)
            elif cmd == 0x26:
                self._funcstarts = struct.unpack("<II", d[off + 8:off + 16])
            elif cmd in (0xC, 0x18, 0x1F, 0x8000001F):
                name_off = struct.unpack("<I", d[off + 8:off + 12])[0]
                self.dylibs.append(
                    d[off + name_off:off + cmdsize].split(b"\0")[0].decode("utf8", "ignore"))
            off += cmdsize

    def symbols(self):
        symoff, nsyms, stroff, _ = self._symtab
        out = []
        for i in range(nsyms):
            p = symoff + i * 16
            n_strx, _, _, _, n_value = struct.unpack("<IBBHQ", self.data[p:p + 16])
            end = self.data.index(b"\0", stroff + n_strx)
            out.append((n_value, self.data[stroff + n_strx:end].decode("utf8", "replace")))
        return out

    def read(self, addr: int, size: int) -> bytes:
        for sect in self.sections:
            if sect["addr"] <= addr < sect["addr"] + sect["size"]:
                start = sect["offset"] + (addr - sect["addr"])
                return self.data[start:start + size]
        return b""

    def section(self, name: str) -> dict:
        for sect in self.sections:
            if sect["name"] == name:
                return sect
        raise SystemExit(f"找不到段 {name}")


def cmd_info(m: MachO):
    print(f"文件 {len(m.data)} 字节，{len(m.sections)} 个段")
    for sect in m.sections:
        print(f"  {sect['seg']},{sect['name']:<18} addr=0x{sect['addr']:x} "
              f"size={sect['size']} off=0x{sect['offset']:x}")
    print(f"\n符号 {len(m.symbols())} 个，依赖库 {len(m.dylibs)} 个")
    for lib in m.dylibs:
        print("  ", lib)


def cmd_syms(m: MachO, keyword: str):
    hits = [(a, n) for a, n in m.symbols() if keyword.lower() in n.lower()]
    print(f"匹配 {len(hits)} 个：")
    for addr, name in hits:
        print(f"  0x{addr:x} {name}")


def cmd_disasm(m: MachO, addr: int, count: int):
    if Cs is None:
        raise SystemExit("需要 capstone：pip install capstone")
    md = Cs(CS_ARCH_ARM64, CS_MODE_ARM)
    syms = sorted((a, n) for a, n in m.symbols() if a)
    addrs = [a for a, _ in syms]
    code = m.read(addr, count * 4)
    for ins in md.disasm(code, addr):
        idx = bisect.bisect_right(addrs, ins.address) - 1
        note = f"  ; {syms[idx][1]}" if idx >= 0 and syms[idx][0] == ins.address else ""
        print(f"0x{ins.address:x}: {ins.mnemonic:<8} {ins.op_str}{note}")


def cmd_scan(m: MachO):
    """扫 __text 里的关键常量，定位端口与分片长度。"""
    if Cs is None:
        raise SystemExit("需要 capstone：pip install capstone")
    text = m.section("__text")
    code = m.data[text["offset"]:text["offset"] + text["size"]]
    syms = sorted((a, n) for a, n in m.symbols()
                  if a and text["addr"] <= a <= text["addr"] + text["size"])
    addrs = [a for a, _ in syms]

    def owner(pos):
        i = bisect.bisect_right(addrs, pos) - 1
        return syms[i][1] if i >= 0 else "?"

    targets = {0x1394: "PORT 5012", 0x1395: "PORT 5013", 0x578: "1400", 0x564: "1380",
               0x14: "20", 0x20: "32", 0x90: "0x90", 0xCC: "0xCC"}
    md = Cs(CS_ARCH_ARM64, CS_MODE_ARM)
    for ins in md.disasm(code, text["addr"]):
        if ins.mnemonic in ("mov", "movz", "movk") and "#0x" in ins.op_str:
            try:
                value = int(ins.op_str.split("#0x")[1], 16)
            except ValueError:
                continue
            if value in targets:
                print(f"0x{ins.address:x} {ins.op_str:<16} {targets[value]:<10} "
                      f"在 {owner(ins.address)[:80]}")


def main(argv: list[str]) -> int:
    if len(argv) < 3:
        print(__doc__)
        return 1
    action, binary = argv[1], argv[2]
    m = MachO(binary)
    if action == "info":
        cmd_info(m)
    elif action == "syms":
        cmd_syms(m, argv[3] if len(argv) > 3 else "")
    elif action == "disasm":
        cmd_disasm(m, int(argv[3], 16), int(argv[4]) if len(argv) > 4 else 200)
    elif action == "scan":
        cmd_scan(m)
    else:
        print(__doc__)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
