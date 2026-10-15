#!/usr/bin/env python3
"""手机空闲时测守护进程的真实打分延迟：每次换一组新候选（避免命中引擎缓存），上文固定且已预解码。
用法：python3 -I bench_daemon.py [轮数]    （需要守护进程在跑；经 adb forward 访问）"""
import os, socket, struct, subprocess, sys, time
ADB = os.environ.get("ADB", "adb"); PORT = 17920; SEP = "\x1f"
RIME = "/sdcard/Android/data/com.osfans.trime/files/rime"
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
subprocess.run([ADB, "forward", f"tcp:{PORT}", f"tcp:{PORT}"], check=True, capture_output=True)
s = socket.create_connection(("127.0.0.1", PORT), timeout=30)
assert rpc(s, ["H", sh(f"cat {RIME}/llm_token")])[0] == "OK"
ctx = "我今天去公司"
while not (rpc(s, ["P", ctx])[0] == "1" and rpc(s, ["I"])[0] == "1"): time.sleep(0.2)
time.sleep(0.8)
pool = ["经理","经历","精力","敬礼","警力","工作","公司","共识","公式","个数","时间","事件","实践","市建","是见","项目","相木","向木","象牙","想法","下载","夏在","吓在","效率","小路","笑露","需要","许要","虚药","须要"]
N = int(sys.argv[1]) if len(sys.argv) > 1 else 40
NC = int(os.environ.get("CANDS", "5"))
lat, skipped = [], 0
for i in range(N):
    cands = [pool[(i * 3 + k * 7) % len(pool)] for k in range(NC)]
    if len(set(cands)) < NC: continue
    t0 = time.time(); r = rpc(s, ["S", "0", ctx] + cands); dt = (time.time() - t0) * 1000
    if r[0] == "R": lat.append(dt)
    else: skipped += 1
    time.sleep(0.25)      # 模拟打字间隔
lat.sort(); n = len(lat)
print(f"n={n} skipped={skipped} p50={lat[n//2]:.0f}ms p90={lat[int(n*0.9)]:.0f}ms max={lat[-1]:.0f}ms")
