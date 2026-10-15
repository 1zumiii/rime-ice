"""最小的 ELF64 动态符号表读取器（没有 NDK 的 nm 时用）。
用法: python3 -I elfsyms.py <so 文件> [前缀...]
输出：导出（已定义）的动态符号数量、匹配前缀的符号，以及导入（未定义）的符号里匹配前缀的。
"""
import struct
import sys

path = sys.argv[1]
prefixes = tuple(sys.argv[2:]) or ("lua_", "luaL_", "luaopen_", "dl")
data = open(path, "rb").read()
assert data[:4] == b"\x7fELF" and data[4] == 2 and data[5] == 1, "need ELF64 little-endian"

(e_shoff,) = struct.unpack_from("<Q", data, 0x28)
e_shentsize, e_shnum, e_shstrndx = struct.unpack_from("<HHH", data, 0x3A)

secs = []
for i in range(e_shnum):
    off = e_shoff + i * e_shentsize
    name, typ, flags, addr, offset, size, link, info, align, entsize = struct.unpack_from("<IIQQQQIIQQ", data, off)
    secs.append(dict(name=name, type=typ, offset=offset, size=size, link=link, entsize=entsize))

shstr = secs[e_shstrndx]


def cstr(base, idx):
    start = base + idx
    end = data.index(b"\x00", start)
    return data[start:end].decode("utf8", "replace")


def sec_name(s):
    return cstr(shstr["offset"], s["name"])


dynsym = next((s for s in secs if s["type"] == 11), None)  # SHT_DYNSYM
assert dynsym, "no .dynsym"
dynstr = secs[dynsym["link"]]

exported, imported = [], []
for i in range(dynsym["size"] // dynsym["entsize"]):
    off = dynsym["offset"] + i * dynsym["entsize"]
    st_name, st_info, st_other, st_shndx, st_value, st_size = struct.unpack_from("<IBBHQQ", data, off)
    if st_name == 0:
        continue
    name = cstr(dynstr["offset"], st_name)
    (imported if st_shndx == 0 else exported).append((name, st_other & 3))  # st_other&3 = visibility

print("file:", path)
print("dynamic symbols: exported(defined)=%d imported(undefined)=%d" % (len(exported), len(imported)))
hits = [n for n, _ in exported if n.startswith(prefixes)]
print("exported symbols matching %s: %d" % (list(prefixes), len(hits)))
for n in sorted(hits)[:40]:
    print("   +", n)
ihits = [n for n, _ in imported if n.startswith(prefixes)]
print("imported symbols matching: %d" % len(ihits))
for n in sorted(ihits)[:20]:
    print("   -", n)
print("\nfirst 25 exported symbols overall:")
for n, _ in exported[:25]:
    print("   ", n)
needed = []
dyn = next((s for s in secs if s["type"] == 6), None)  # SHT_DYNAMIC
if dyn:
    for i in range(dyn["size"] // 16):
        tag, val = struct.unpack_from("<qQ", data, dyn["offset"] + i * 16)
        if tag == 1:  # DT_NEEDED
            needed.append(cstr(dynstr["offset"], val))
print("\nDT_NEEDED:", needed)
