"""Windows 版自测：现场做各种压缩包，用 UNPACK_TEST 不弹窗地跑解压.exe，检查解出来的文件名和内容。

用法：python run_tests.py <放着 解压.exe 和 7z.exe 的目录>
"""
import hashlib, os, shutil, subprocess, sys, tempfile, zipfile

APP = os.path.abspath(sys.argv[1])
EXE = next(os.path.join(APP, n) for n in os.listdir(APP) if n.lower().endswith(".exe") and n.lower() != "7z.exe")
SZ = os.path.join(APP, "7z.exe")
WORK = tempfile.mkdtemp(prefix="unpack-test-")
FIX = os.path.join(WORK, "fixtures")
os.makedirs(FIX)
failures = []

TREE = {"hello.txt": "hello world\n", "子目录/中文.txt": "中文内容 ✓\n"}


def write_tree(root, tree):
    for rel, text in tree.items():
        p = os.path.join(root, *rel.split("/"))
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "w", encoding="utf-8", newline="") as f:
            f.write(text)


def sz(*args, cwd=FIX):
    subprocess.run([SZ, *args], cwd=cwd, check=True, stdout=subprocess.DEVNULL)


def legacy_zip(path, files, encoding):
    """文件名按旧编码（GBK/Shift-JIS…）存、不打 UTF-8 标记的 zip：先用等长的 ASCII 占位名写，再把字节换掉"""
    repl = []
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as z:
        for i, (name, text) in enumerate(files):
            raw = name.encode(encoding)
            if all(b < 128 for b in raw):
                z.writestr(name, text.encode("utf-8"))
                continue
            stem = f"P{i}_".encode()
            ph = (stem + b"X" * (len(raw) - len(stem))) if len(raw) >= len(stem) else None
            assert ph is not None and len(ph) == len(raw)
            z.writestr(ph.decode(), text.encode("utf-8"))
            repl.append((ph, raw))
    data = open(path, "rb").read()
    for ph, raw in repl:
        assert data.count(ph) == 2, ph   # 本地文件头 + 中央目录各一次
        data = data.replace(ph, raw)
    open(path, "wb").write(data)


def run(case, items, dest, pw=None, save=None, expect_ok=True, extra=None):
    os.makedirs(dest, exist_ok=True)
    log = os.path.join(WORK, case + ".log")
    env = {k: v for k, v in os.environ.items() if not k.startswith("UNPACK_")}
    env.update(UNPACK_TEST=";".join(items), UNPACK_DEST=dest, UNPACK_LOG=log)
    if pw is not None: env["UNPACK_PW"] = pw
    if save is not None: env["UNPACK_SAVE"] = save
    env.update(extra or {})
    r = subprocess.run([EXE], env=env, timeout=300)
    out = open(log, encoding="utf-8").read() if os.path.exists(log) else "(no log)"
    print(f"--- {case} (exit {r.returncode})\n{out}")
    if (r.returncode == 0) != expect_ok:
        failures.append(f"{case}: exit code {r.returncode}, expected {'0' if expect_ok else 'non-zero'}")
    return out


def check_tree(case, root, tree):
    for rel, text in tree.items():
        p = os.path.join(root, *rel.split("/"))
        if not os.path.isfile(p):
            failures.append(f"{case}: missing {p}")
            print("    contents:", [os.path.relpath(os.path.join(d, f), root) for d, _, fs in os.walk(root) for f in fs] if os.path.isdir(root) else "(no dir)")
        elif open(p, encoding="utf-8", newline="").read() != text:
            failures.append(f"{case}: wrong content in {p}")


def check_absent(case, root, names):
    for d, dirs, files in os.walk(root):
        for n in dirs + files:
            if n in names:
                failures.append(f"{case}: junk not removed: {os.path.join(d, n)}")


def D(case):
    return os.path.join(WORK, "out", case)


# ---- 素材 ----
write_tree(os.path.join(FIX, "src"), TREE)
with open(os.path.join(FIX, "big.bin"), "wb") as f:
    f.write(os.urandom(300_000))
big_md5 = hashlib.md5(open(os.path.join(FIX, "big.bin"), "rb").read()).hexdigest()

sz("a", "-tzip", "plain.zip", "src")
sz("a", "-t7z", "plain.7z", "src")
sz("a", "-t7z", "-p123", "-mhe=on", "pw_hdr.7z", "src")       # 文件名也加密
sz("a", "-t7z", "-p456", "pw_book.7z", "src")                 # 只加密内容，靠密码本自动试
sz("a", "-ttar", "plain.tar", "src")
sz("a", "-tgzip", "plain.tar.gz", "plain.tar")
os.remove(os.path.join(FIX, "plain.tar"))
sz("a", "-t7z", "-mx=0", "-v100k", "split.7z", "big.bin")    # split.7z.001 … .003
legacy_zip(os.path.join(FIX, "gbk.zip"), [("中文测试.txt", "简体内容\n"), ("资料/报告.txt", "报告内容\n")], "gbk")
legacy_zip(os.path.join(FIX, "sjis.zip"), [("日本語.txt", "にほんご\n"), ("readme.txt", "hi\n")], "shift_jis")
legacy_zip(os.path.join(FIX, "macutf8.zip"), [("照片说明.txt", "mac\n"), ("备注.txt", "note\n")], "utf-8")   # Mac 访达式：UTF-8 不打标记
with zipfile.ZipFile(os.path.join(FIX, "junk.zip"), "w") as z:
    z.writestr("a.txt", "A\n"); z.writestr("b.txt", "B\n")
    z.writestr("__MACOSX/._a.txt", "x"); z.writestr(".DS_Store", "x"); z.writestr("Thumbs.db", "x")
F = lambda n: os.path.join(FIX, n)

# ---- 用例 ----
run("zip", [F("plain.zip")], D("zip")); check_tree("zip", os.path.join(D("zip"), "src"), TREE)
run("7z", [F("plain.7z")], D("7z")); check_tree("7z", os.path.join(D("7z"), "src"), TREE)
run("7z-password", [F("pw_hdr.7z")], D("pwhdr"), pw="123"); check_tree("7z-password", os.path.join(D("pwhdr"), "src"), TREE)
out = run("7z-password-book", [F("pw_book.7z")], D("pwbook"), save="456"); check_tree("7z-password-book", os.path.join(D("pwbook"), "src"), TREE)
if "pw=456" not in out: failures.append("7z-password-book: password book was not used")
out = run("7z-wrong-password", [F("pw_hdr.7z")], D("pwbad"), pw="bad", expect_ok=False)
if "FAIL" not in out: failures.append("7z-wrong-password: no FAIL line")
run("tar.gz", [F("plain.tar.gz")], D("tgz")); check_tree("tar.gz", os.path.join(D("tgz"), "src"), TREE)
if os.path.exists(os.path.join(D("tgz"), "plain.tar")): failures.append("tar.gz: inner .tar left behind")
run("split-7z", [F("split.7z.002")], D("split"))   # 拖第二卷也要从第一卷开始
p = os.path.join(D("split"), "big.bin")
if not os.path.isfile(p) or hashlib.md5(open(p, "rb").read()).hexdigest() != big_md5: failures.append("split-7z: big.bin missing or different")
out = run("gbk-zip", [F("gbk.zip")], D("gbk")); check_tree("gbk-zip", os.path.join(D("gbk"), "gbk"), {"中文测试.txt": "简体内容\n", "资料/报告.txt": "报告内容\n"})
if "enc=GBK" not in out: failures.append("gbk-zip: encoding not detected as GBK")
out = run("sjis-zip", [F("sjis.zip")], D("sjis")); check_tree("sjis-zip", os.path.join(D("sjis"), "sjis"), {"日本語.txt": "にほんご\n", "readme.txt": "hi\n"})
if "enc=Shift-JIS" not in out: failures.append("sjis-zip: encoding not detected as Shift-JIS")
run("mac-utf8-zip", [F("macutf8.zip")], D("macutf8")); check_tree("mac-utf8-zip", os.path.join(D("macutf8"), "macutf8"), {"照片说明.txt": "mac\n", "备注.txt": "note\n"})
run("junk", [F("junk.zip")], D("junk")); check_tree("junk", os.path.join(D("junk"), "junk"), {"a.txt": "A\n", "b.txt": "B\n"})
check_absent("junk", D("junk"), {"__MACOSX", ".DS_Store", "Thumbs.db", "._a.txt"})
# 智能放置：同名已存在就加编号
run("unique-name", [F("plain.zip")], D("zip")); check_tree("unique-name", os.path.join(D("zip"), "src 2"), TREE)
# 压缩：文件夹 → zip，名字存 UTF-8，再解回来对一遍
run("compress", [os.path.join(FIX, "src")], D("compress"))
zp = os.path.join(D("compress"), "src.zip")
if not os.path.isfile(zp): failures.append("compress: src.zip not created")
else:
    names = zipfile.ZipFile(zp).namelist()
    if "src/子目录/中文.txt" not in names: failures.append(f"compress: names wrong {names}")
    run("compress-roundtrip", [zp], D("roundtrip")); check_tree("compress-roundtrip", os.path.join(D("roundtrip"), "src"), TREE)

# 压缩选项：7z + 密码 + 加密文件名 + 分卷，再解回来对一遍
big = os.path.join(FIX, "optsrc"); write_tree(big, TREE)
with open(os.path.join(big, "big.bin"), "wb") as f: f.write(os.urandom(3_000_000))
run("compress-7z-split", [big], D("opts"), pw="abc", extra={"UNPACK_FORMAT": "7z", "UNPACK_LEVEL": "9", "UNPACK_SPLIT": "1"})
vols = sorted(n for n in os.listdir(D("opts")) if n.startswith("optsrc.7z."))
if len(vols) < 3: failures.append(f"compress-7z-split: expected 3+ volumes, got {vols}")
else:
    r = subprocess.run([SZ, "l", "-p", os.path.join(D("opts"), vols[0])], stdin=subprocess.DEVNULL, capture_output=True, text=True, encoding="utf-8", errors="replace")
    if r.returncode == 0: failures.append("compress-7z-split: names readable without password (-mhe not on)")
    run("compress-7z-split-roundtrip", [os.path.join(D("opts"), vols[1])], D("optsback"), pw="abc")
    check_tree("compress-7z-split-roundtrip", os.path.join(D("optsback"), "optsrc"), TREE)
run("compress-zip-aes-store", [os.path.join(FIX, "src")], D("aes"), pw="xyz", extra={"UNPACK_LEVEL": "0", "UNPACK_SPLIT": "100"})
r = subprocess.run([SZ, "l", "-slt", "-pxyz", os.path.join(D("aes"), "src.zip")], capture_output=True, text=True, encoding="utf-8", errors="replace")
if "AES-256 Store" not in r.stdout: failures.append("compress-zip-aes-store: not AES-256 Store / not a single src.zip")

# 改包：zip 里加到子文件夹、改文件夹名、删文件；加密 7z 改完文件名还是加密的；加密 zip 新加的也是 AES；分卷包不让改
TAB = "\t"
new = os.path.join(FIX, "新加.txt"); open(new, "w", encoding="utf-8").write("new\n")
ez = os.path.join(FIX, "edit.zip"); sz("a", "-tzip", "-mcu=on", ez, "src")
out = run("edit-zip", [ez], D("edit"), extra={"UNPACK_EDIT": f"add{TAB}src\\子目录{TAB}{new};rename{TAB}src\\子目录{TAB}改过的;delete{TAB}src\\hello.txt"})
names = zipfile.ZipFile(ez).namelist()
for want in ["src/改过的/新加.txt", "src/改过的/中文.txt"]:
    if want not in names: failures.append(f"edit-zip: missing {want} in {names}")
if "src/hello.txt" in names: failures.append("edit-zip: hello.txt not deleted")
e7 = os.path.join(FIX, "edit.7z"); sz("a", "-pabc", "-mhe=on", e7, "src")
out = run("edit-7z-hdr", [e7], D("edit"), pw="abc", extra={"UNPACK_EDIT": f"add{TAB}{TAB}{new}"})
if "hdr=True" not in out or "新加.txt" not in out: failures.append("edit-7z-hdr: header encryption lost or file not added")
ea = os.path.join(FIX, "edit-aes.zip"); sz("a", "-tzip", "-pxyz", "-mem=AES256", ea, "src")
out = run("edit-zip-aes", [ea], D("edit"), pw="xyz", extra={"UNPACK_EDIT": f"add{TAB}{TAB}{new}"})
if not any("新加.txt" in l and "AES" in l for l in out.splitlines()): failures.append("edit-zip-aes: added file not AES")
out = run("edit-split-blocked", [F("split.7z.001")], D("edit"), extra={"UNPACK_EDIT": f"delete{TAB}x"})
if "BLOCKED" not in out: failures.append("edit-split-blocked: split archive was not blocked")

# RAR：机器上有 WinRAR 的 Rar.exe 才测（官方 7-Zip 自带 RAR 解码）
rar = r"C:\Program Files\WinRAR\Rar.exe"
if os.path.exists(rar):
    subprocess.run([rar, "a", "-r", "-ma5", "-hp789", F("enc.rar"), "src"], cwd=FIX, check=True, stdout=subprocess.DEVNULL)
    subprocess.run([rar, "a", "-r", "-ma5", "-v100k", "-m0", F("vol.rar"), "big.bin"], cwd=FIX, check=True, stdout=subprocess.DEVNULL)
    run("rar5-password", [F("enc.rar")], D("rar"), pw="789"); check_tree("rar5-password", os.path.join(D("rar"), "src"), TREE)
    run("rar-volumes", [F("vol.part2.rar")], D("rarvol"))
    p = os.path.join(D("rarvol"), "big.bin")
    if not os.path.isfile(p) or hashlib.md5(open(p, "rb").read()).hexdigest() != big_md5: failures.append("rar-volumes: big.bin missing or different")
else:
    print("(no WinRAR on this machine, RAR cases skipped)")

print("\n==== RESULT ====")
if failures:
    for f in failures: print("FAIL:", f)
    sys.exit(1)
print("ALL PASSED")
