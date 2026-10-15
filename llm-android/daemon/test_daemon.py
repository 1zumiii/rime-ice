#!/usr/bin/env python3
"""rimellmd 端到端测试（手机上跑着守护进程，经 adb forward 从 Mac 访问）。
用法：python3 -I llm-android/daemon/test_daemon.py [--chaos]
  默认：协议、认证、非法输入、打分正确性、延迟
  --chaos：再做破坏性测试（kill -9 工作进程、SIGSTOP 冻结工作进程），验证监督进程自动恢复。"""
import json, os, socket, struct, subprocess, sys, time

ADB = os.environ.get("ADB", "adb")
RIME = "/sdcard/Android/data/com.osfans.trime/files/rime"
PORT = 17920
SEP = "\x1f"
fails = 0


def sh(cmd):
    return subprocess.run([ADB, "shell", cmd], capture_output=True, text=True, timeout=30).stdout.replace("\r", "").strip()


def check(name, cond, extra=""):
    global fails
    print(("PASS " if cond else "FAIL ") + name + (f"  [{extra}]" if extra else ""))
    if not cond:
        fails += 1


def frame(fields):
    b = SEP.join(fields).encode()
    return struct.pack(">I", len(b)) + b


def recv_exact(s, n):
    buf = b""
    while len(buf) < n:
        c = s.recv(n - len(buf))
        if not c:
            raise EOFError
        buf += c
    return buf


def rpc(s, fields):
    s.sendall(frame(fields))
    n = struct.unpack(">I", recv_exact(s, 4))[0]
    return recv_exact(s, n).decode().split(SEP)


def connect(token=None, auth=True):
    s = socket.create_connection(("127.0.0.1", PORT), timeout=5)
    if auth:
        r = rpc(s, ["H", token or sh(f"cat {RIME}/llm_token")])
        assert r[0] == "OK", r
    return s


def pids():
    return sh("pidof rimellmd").split()


def status():
    s = connect()
    try:
        return json.loads(rpc(s, ["G"])[0])
    finally:
        s.close()


def wait_ready(s, limit=30):
    t0 = time.time()
    while time.time() - t0 < limit:
        if rpc(s, ["P", "他在公司当"])[0] == "1" and rpc(s, ["I"])[0] == "1":
            return time.time() - t0
        time.sleep(0.1)
    return None


subprocess.run([ADB, "forward", f"tcp:{PORT}", f"tcp:{PORT}"], check=True, capture_output=True)
check("daemon processes running (supervisor + worker)", len(pids()) == 2, str(pids()))

# ---- 认证与非法输入
s = socket.create_connection(("127.0.0.1", PORT), timeout=5)
check("heartbeat works without auth", rpc(s, ["B"]) == ["PONG"])
s.close()
s = socket.create_connection(("127.0.0.1", PORT), timeout=5)
s.sendall(frame(["S", "0", "他在公司当", "经理", "经历"]))
try:
    s.settimeout(3); r = s.recv(10)
except Exception:
    r = b""
check("unauthenticated request is dropped", r == b"")
s.close()
s = socket.create_connection(("127.0.0.1", PORT), timeout=5)
r = rpc(s, ["H", "0" * 32])
check("wrong token rejected", r[0] == "ERR", str(r))
s.close()
s = connect()
s.sendall(struct.pack(">I", 10 * 1024 * 1024) + b"x" * 100)   # 超过上限的长度
try:
    s.settimeout(3); r = s.recv(10)
except Exception:
    r = b""
check("oversize frame -> connection closed", r == b"")
s.close()
s = connect()
s.sendall(b"\xff\xff")  # 残缺的头
time.sleep(0.2); s.close()
check("daemon survives garbage", status()["errors"] >= 0)
s = connect()
check("unknown opcode handled", rpc(s, ["Q"])[0] == "ERR")

# ---- 推理
t = wait_ready(s)
check("model loads and context prepares", t is not None, f"{t:.1f}s" if t else "")
time.sleep(0.5)
cands = ["经理", "经历", "精力", "敬礼", "警力"]
r = rpc(s, ["S", "0", "他在公司当"] + cands)
check("score returns a ranking", r[0] == "R" and len(r) == 1 + 2 * len(cands), str(r[:5]))
check("ranking is sensible (经理 first)", r[0] == "R" and r[1] == "经理", " > ".join(r[1::2]))
lat = []
for _ in range(30):
    t0 = time.time(); r = rpc(s, ["S", "0", "他在公司当"] + cands); lat.append((time.time() - t0) * 1000)
lat.sort()
print(f"     round-trip latency via adb forward (prepared context): p50={lat[15]:.0f} ms max={lat[-1]:.0f} ms")
r = rpc(s, ["S", "0", "一个没有预解码过的上文"] + cands)
check("unprepared context is skipped, not decoded synchronously", r[0] == "N" and r[1] == "unprepared", str(r))
r = rpc(s, ["S", "1", "他在公司当"] + ["经理"])
check("single candidate -> no ranking", r[0] == "N")
check("config accepted", rpc(s, ["C", "idle_unload_sec", "1200"]) == ["OK"])
check("screen-off hint accepted", rpc(s, ["Z", "1"]) == ["OK"])
st = status()
check("status reflects screen off (idle limit unchanged when screen_off_sec=0)", st["screen"] == "off" and st["idle_unload_sec"] == 1200, f'{st["screen"]} {st["idle_unload_sec"]}')
rpc(s, ["Z", "0"])
st = status()
check("status reflects screen on", st["screen"] == "on" and st["idle_unload_sec"] == 1200)
print("     status:", json.dumps(st, ensure_ascii=False))
check("status file is fresh", abs(int(sh(f"date +%s")) - json.loads(sh(f"cat {RIME}/ai_status.json"))["ts"]) < 6)
s.close()

# ---- 并发：多个连接同时打分
import threading
res = []
def worker():
    c = connect(); ok = 0
    for _ in range(20):
        r = rpc(c, ["S", "0", "他在公司当"] + cands)
        ok += r[0] in ("R", "N")
    res.append(ok); c.close()
th = [threading.Thread(target=worker) for _ in range(4)]
[t.start() for t in th]; [t.join() for t in th]
check("4 concurrent clients x 20 requests all answered", res == [20] * 4, str(res))
check("no connection leak", status()["clients"] <= 1)

if "--chaos" in sys.argv:
    print("--- chaos")
    before = status()
    worker_pid = str(before["pid"])
    old_token = sh(f"cat {RIME}/llm_token")
    sh(f"kill -9 {worker_pid}")
    t0 = time.time(); st = None
    while time.time() - t0 < 30:
        try:
            st = status(); break
        except Exception:
            time.sleep(0.5)
    check("worker killed with SIGKILL -> supervisor restarts it", st is not None and str(st["pid"]) != worker_pid, f"{time.time()-t0:.1f}s")
    check("restart is recorded with the reason", st and st["restarts"] == before["restarts"] + 1 and "SIGKILL" in st["last_exit"], st and st["last_exit"])
    check("new token issued on restart", sh(f"cat {RIME}/llm_token") != old_token)
    s = connect(); check("new worker serves requests", wait_ready(s) is not None); s.close()

    worker_pid = str(status()["pid"]); n_before = status()["restarts"]
    sh(f"kill -STOP {worker_pid}")
    t0 = time.time(); st = None
    while time.time() - t0 < 45:
        time.sleep(1)
        try:
            c = socket.create_connection(("127.0.0.1", PORT), timeout=2)
            c.settimeout(2)
            try:
                if rpc(c, ["B"]) == ["PONG"] and str(status()["pid"]) != worker_pid:
                    st = status(); c.close(); break
            except Exception:
                pass
            c.close()
        except Exception:
            pass
    check("frozen worker (SIGSTOP) -> supervisor detects and replaces it", st is not None, f"{time.time()-t0:.0f}s")
    check("hang recorded", st and "hung" in st["last_exit"] and st["restarts"] == n_before + 1, st and st["last_exit"])
    sh(f"kill -CONT {worker_pid} 2>/dev/null")

print("ALL OK" if fails == 0 else f"{fails} FAILED")
sys.exit(1 if fails else 0)
