#!/usr/bin/env python3
"""给 Mach-O 可执行文件加一条 LC_LOAD_DYLIB（相当于 TrollFools 的注入步骤）。

    python3 tools/inject_dylib.py <可执行文件> <@executable_path 下的 dylib 路径>

例：
    python3 tools/inject_dylib.py dist/TrollStoreLiteTV.app/TrollStoreLiteTV \
        @executable_path/Frameworks/hello.dylib

原理：Mach-O 头后面紧跟着 load commands，之后才是段数据。
      只要 load commands 末尾到第一段数据之间有空隙，就能就地插入一条新命令，
      不需要重排文件。插完签名会失效，必须重新签名（ldid -S）才能运行。
"""

from __future__ import annotations

import struct
import sys

LC_LOAD_DYLIB = 0x0C
LC_REQ_DYLD = 0x80000000
MH_MAGIC_64 = 0xFEEDFACF
MH_MAGIC_32 = 0xFEEDFACE
LC_SEGMENT_64 = 0x19
LC_SEGMENT = 0x01


def align8(n: int) -> int:
    return (n + 7) & ~7


def parse(data: bytearray):
    magic = struct.unpack_from("<I", data, 0)[0]
    if magic == MH_MAGIC_64:
        is64, hdr = True, 32
    elif magic == MH_MAGIC_32:
        is64, hdr = False, 28
    else:
        raise SystemExit(f"不是 Mach-O（magic=0x{magic:08x}）")

    ncmds = struct.unpack_from("<I", data, 16)[0]
    sizeofcmds = struct.unpack_from("<I", data, 20)[0]

    off = hdr
    first_data = None
    cmds = []
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from("<II", data, off)
        cmds.append((cmd, cmdsize, off))
        if cmd == LC_SEGMENT_64:
            fileoff = struct.unpack_from("<Q", data, off + 40)[0]
            if fileoff > 0 and (first_data is None or fileoff < first_data):
                first_data = fileoff
        elif cmd == LC_SEGMENT:
            fileoff = struct.unpack_from("<I", data, off + 32)[0]
            if fileoff > 0 and (first_data is None or fileoff < first_data):
                first_data = fileoff
        off += cmdsize

    if first_data is None:
        first_data = hdr + sizeofcmds
    return is64, hdr, ncmds, sizeofcmds, first_data, cmds


def make_load_dylib(path: str) -> bytes:
    raw = path.encode() + b"\x00"
    size = align8(24 + len(raw))
    cmd = LC_LOAD_DYLIB   # 不带 LC_REQ_DYLD：0x8000000c 会让 otool/dyld 认不出
    # cmd, cmdsize, name offset(24), timestamp, current_version, compatibility_version
    body = struct.pack("<IIIIII", cmd, size, 24, 2, 0x10000, 0x10000)
    return body + raw + b"\x00" * (size - len(body) - len(raw))


def inject(binary: str, dylib_path: str) -> None:
    data = bytearray(open(binary, "rb").read())
    is64, hdr, ncmds, sizeofcmds, first_data, cmds = parse(data)

    for cmd, _, off in cmds:
        if cmd & 0x7FFFFFFF == LC_LOAD_DYLIB:
            name_off = struct.unpack_from("<I", data, off + 8)[0]
            existing = data[off + name_off:data.find(b"\x00", off + name_off)].decode()
            if existing == dylib_path:
                print(f"已存在，跳过: {dylib_path}")
                return

    lc = make_load_dylib(dylib_path)
    end = hdr + sizeofcmds
    free = first_data - end
    if free < len(lc):
        raise SystemExit(f"头后空隙不足：需要 {len(lc)} 字节，只有 {free} 字节")

    data[end:end + len(lc)] = lc
    struct.pack_into("<I", data, 16, ncmds + 1)
    struct.pack_into("<I", data, 20, sizeofcmds + len(lc))
    open(binary, "wb").write(data)
    print(f"已注入 {dylib_path}（+{len(lc)} 字节，ncmds {ncmds}→{ncmds + 1}）")
    print("注意：签名已失效，需要重新 ldid -S 并加入信任缓存")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit(__doc__)
    inject(sys.argv[1], sys.argv[2])
