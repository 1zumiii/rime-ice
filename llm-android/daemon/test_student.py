#!/usr/bin/env python3
"""学生模式的端到端检查：在手机上单独起一个守护进程（端口 17921，不影响 Trime 里正在用的），
用几组同音词核对排序，并测候选 6 个时的打分延迟。
用法：python3 -I test_student.py <rimellmd 二进制> <student.gguf> <student.vocab.txt>"""
import os, socket, struct, subprocess, sys, time
ADB = os.environ.get("ADB", "adb"); PORT = 17921; SEP = "\x1f"; D = "/data/local/tmp/stutest"
def sh(c): return subprocess.run([ADB, "shell", c], capture_output=True, text=True).stdout.replace("\r", "").strip()
def fr(f): b = SEP.join(f).encode(); return struct.pack(">I", len(b)) + b
def rx(s, n):
    b = b""
    while len(b) < n:
        c = s.recv(n - len(b))
        if not c: raise EOFError
        b += c
    return b
def rpc(s, f):
    s.sendall(fr(f)); n = struct.unpack(">I", rx(s, 4))[0]; return rx(s, n).decode().split(SEP)
binp, gguf, vocab = sys.argv[1:4]
sh(f"mkdir -p {D}/rime; pkill -f '[r]imellmd.*{PORT}'")
for f in (binp, gguf, vocab): subprocess.run([ADB, "push", f, D + "/"], check=True, capture_output=True)
sh(f"chmod 755 {D}/rimellmd")
name = os.path.basename
sh(f"cd {D}; (setsid nohup ./rimellmd --model {D}/{name(gguf)} --student-vocab {D}/{name(vocab)} --rime-dir {D}/rime --log-dir {D} --port {PORT} --threads 2 --idle-sec 0 --n-seq-max 10 > {D}/out.log 2>&1 < /dev/null &) >/dev/null 2>&1")
time.sleep(1.5)
subprocess.run([ADB, "forward", f"tcp:{PORT}", f"tcp:{PORT}"], check=True, capture_output=True)
s = socket.create_connection(("127.0.0.1", PORT), timeout=30)
assert rpc(s, ["H", sh(f"cat {D}/rime/llm_token")])[0] == "OK"
cases = [("他在公司当", ["经理", "经历", "精力", "敬礼", "警力"], "经理"),
         ("我最近没有太多", ["精力", "经历", "经理", "敬礼", "警力"], "精力"),
         ("昨天下午我去参加了一次", ["经理", "经历", "精力"], "经历"),
         ("请你在明天之前把报告", ["提交", "提教", "体交"], "提交"),
         ("今天天气真", ["好", "号", "耗", "浩"], "好"),
         ("他是我们公司的", ["经理", "经历", "精力"], "经理")]
ok = 0
for ctx, cands, want in cases:
    t0 = time.time()
    while True:
        r = rpc(s, ["S", "1", ctx] + cands)          # allow_sync=1：上文没预解码好也现场解码
        if r[0] == "R" or time.time() - t0 > 30: break
        time.sleep(0.5)
    top = r[1] if r[0] == "R" else "（无结果：%s）" % r
    ok += top == want
    print(f"{'PASS' if top == want else 'FAIL'}  上文「{ctx}」→ {top}（期望 {want}）")
print(f"{ok}/{len(cases)} 通过")
# 延迟：上文已预解码，换 6 组候选
ctx = "我今天去公司"
while not (rpc(s, ["P", ctx])[0] == "1" and rpc(s, ["I"])[0] == "1"): time.sleep(0.2)
time.sleep(0.8)
pool = ["经理","经历","精力","敬礼","警力","工作","公司","共识","公式","个数","时间","事件","实践","市建","是见","项目","相木","向木","象牙","想法","下载","夏在","吓在","效率","小路","笑露","需要","许要","虚药","须要"]
lat, skipped = [], 0
for i in range(40):
    cands = [pool[(i * 3 + k * 7) % len(pool)] for k in range(6)]
    if len(set(cands)) < 6: continue
    t0 = time.time(); r = rpc(s, ["S", "0", ctx] + cands); dt = (time.time() - t0) * 1000
    if r[0] == "R": lat.append(dt)
    else: skipped += 1
    time.sleep(0.25)
lat.sort(); n = len(lat)
print(f"候选 6 个、含进程间通信：n={n} 跳过={skipped} 中位={lat[n//2]:.1f}ms p90={lat[int(n*0.9)]:.1f}ms 最大={lat[-1]:.1f}ms")
# 上文没预解码好（每次换新上文、不发预解码）：学生模式应现场解码而不是跳过
lat2, skipped2 = [], 0
for i in range(30):
    c2 = "我今天去公司开会第" + "一二三四五六七八九十"[i % 10] + "次" * (i // 10 + 1)
    cands = [pool[(i * 3 + k * 7) % len(pool)] for k in range(6)]
    if len(set(cands)) < 6: continue
    t0 = time.time(); r = rpc(s, ["S", "0", c2] + cands); dt = (time.time() - t0) * 1000
    if r[0] == "R": lat2.append(dt)
    else: skipped2 += 1
    time.sleep(0.2)
lat2.sort(); m = len(lat2)
print(f"上文未预解码：n={m} 跳过={skipped2} 中位={lat2[m//2]:.1f}ms 最大={lat2[-1]:.1f}ms")
sh(f"pkill -f '[r]imellmd.*{PORT}'")
