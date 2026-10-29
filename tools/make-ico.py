# 把几张 PNG 打成一个 .ico（每个尺寸直接存 PNG 数据，Windows Vista 起都认）
# 用法：python3 tools/make-ico.py 输出.ico 16.png 24.png 32.png 48.png 64.png 256.png
import struct, sys

out, pngs = sys.argv[1], sys.argv[2:]
datas = [open(p, "rb").read() for p in pngs]
head = struct.pack("<HHH", 0, 1, len(datas))
offset = 6 + 16 * len(datas)
entries = b""
for d in datas:
    w, h = struct.unpack(">II", d[16:24])   # PNG 的 IHDR 里存着宽高
    entries += struct.pack("<BBBBHHII", w % 256, h % 256, 0, 0, 1, 32, len(d), offset)
    offset += len(d)
open(out, "wb").write(head + entries + b"".join(datas))
