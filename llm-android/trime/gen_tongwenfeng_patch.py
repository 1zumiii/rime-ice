#!/usr/bin/env python3
"""生成 tongwenfeng.trime.custom.yaml：把同文风主题改成 GBoard 的习惯布局。
用法：<带 PyYAML 的 python> gen_tongwenfeng_patch.py [同文风主题源文件]
  默认读 ~/Documents/rime-android-port/theme/tongwenfeng.trime.yaml（从手机 shared/ 拉下来的原文件），
  从里面取出符号页的符号，重新排成每页 4 行 × 7 列；其余按键手写。输出到本目录。
  PyYAML：brew 装的 yamllint 自带，例如 `head -1 /opt/homebrew/bin/yamllint` 里就是它的 python。"""
import os, sys, yaml

SRC = sys.argv[1] if len(sys.argv) > 1 else os.path.expanduser("~/Documents/rime-android-port/theme/tongwenfeng.trime.yaml")
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "tongwenfeng.trime.custom.yaml")
theme = yaml.safe_load(open(SRC, encoding="utf-8"))
pk = theme["preset_keyboards"]

ICON_SHIFT, ICON_BS, ICON_ENTER, ICON_EMOJI = "ic@arrow_up_bold_outline", "ic@backspace_outline", "ic@keyboard_return", "ic@emoticon_happy_outline"

def K(**kw): return kw
def spacer(w): return {"width": w}

# ---------------------------------------------------------------- 主页面
def letters():
    keys = []
    for c, d in zip("qwertyuiop", "1234567890"):
        keys.append(K(click=c, long_click=d, key_back_color="bh1", key_text_color="th1"))
    keys.append(spacer(5) | K(key_back_color="bh2", key_text_color="th2"))
    r2 = [("a", dict(long_click="select_all")), ("s", dict(long_click="@")), ("d", dict(long_click="#")), ("f", dict(long_click="$")),
          ("g", dict(long_click="%", swipe_down="date_time")), ("h", dict(long_click="!", swipe_down="+")), ("j", dict(long_click="&", swipe_down="-")),
          ("k", dict(long_click="*", swipe_down="_")), ("l", dict(long_click="(){Left}", swipe_down="="))]
    for c, kw in r2: keys.append(K(click=c, **kw, key_back_color="bh2", key_text_color="th2"))
    keys.append(spacer(5) | K(key_back_color="bh2", key_text_color="th2"))
    keys.append(K(click="Shift_L", long_click="Shift_L", double_click="Shift_L3", composing="delimiter", width=15, hilited_key_back_color="benter", key_back_color="bbs", key_text_color="tbs"))
    r3 = [("z", dict(long_click="`", swipe_down="[]{Left}")), ("x", dict(long_click="cut", swipe_down="{}{Left}")), ("c", dict(long_click="copy", swipe_down=" ")),
          ("v", dict(long_click="paste_clip", swipe_down="paste")), ("b", dict(long_click=";", swipe_down="\\")), ("n", dict(long_click=":")), ("m", dict(long_click="?", swipe_down="|"))]
    for c, kw in r3: keys.append(K(click=c, **kw, key_back_color="bh3", key_text_color="th3"))
    keys.append(K(click="BackSpace2", width=15, key_back_color="bbs", key_text_color="tbs"))
    # 底行：?123 ， 😊 空格 。 回车（GBoard）。?123 长按 = 切换"简洁"（显示/隐藏字母上方的数字提示和小符号，原来 ⌘ 键的长按功能）
    keys.append(K(click="Keyboard_number", long_click="{hide_key_symbol}{hide_key_hint}", width=15, key_back_color="bgn", key_text_color="tgn"))
    keys.append(K(click=",", label="，", long_click="<>{Left}", width=10, key_back_color="bh4", key_text_color="th4"))
    keys.append(K(click="Keyboard_emoji", long_click="liquid_keyboard_switch", width=10, key_back_color="bh4", key_text_color="th4"))
    keys.append(K(click="space", label="拼音", long_click="Mode_switch", swipe_left="Left", swipe_right="Right", swipe_up="Schema_switchcn", width=40, key_text_size="16", key_back_color="bkg", key_text_color="tkg"))
    keys.append(K(click=".", label="。", long_click="clipboard_window", width=10, key_back_color="bh4", key_text_color="th4"))
    keys.append(K(click="Return", label_symbol="wiki", popup=["TrimeWiki", "Settings"], composing="Return1", swipe_up="Escape", width=15, key_back_color="benter", key_text_color="tenter"))
    return keys

# ---------------------------------------------------------------- 数字/符号页（GBoard 的 ?123 页）
def number_page():
    keys = [K(click=d) for d in "1234567890"]
    keys += [K(click=c) for c in ["@", "#", "$", "_", "&", "-", "+", "(", ")", "/"]]
    keys.append(K(click="Keyboard_fh", width=15, key_back_color="bgn", key_text_color="tgn"))     # =\<：进符号页
    keys += [K(click=c) for c in ["、", "“", "”", ":", ";", "!", "?"]]
    keys.append(K(click="BackSpace2", width=15, key_back_color="bbs", key_text_color="tbs"))
    keys.append(K(click="Keyboard_default", width=15, key_back_color="bgn", key_text_color="tgn"))  # 返回
    keys.append(K(click=",", long_click="<", width=10, key_back_color="bgn", key_text_color="tgn"))
    keys.append(K(click="Keyboard_numpad", width=10, key_back_color="bgn", key_text_color="tgn"))   # 1234
    keys.append(K(click="space", long_click="Mode_switch", width=40, key_text_size="16", key_back_color="bkg", key_text_color="tkg"))
    keys.append(K(click=".", long_click=">", width=10, key_back_color="bgn", key_text_color="tgn"))
    keys.append(K(click="Return", long_click="Menu", width=15, key_back_color="benter", key_text_color="tenter"))
    return keys

# ---------------------------------------------------------------- 符号页：每页 4 行 × 7 列
def symbols_of(name):
    out = []
    for k in pk[name]["keys"]:
        c = str(k.get("click", ""))
        if "label" in k or c.startswith(("Keyboard", "BackSpace")): continue
        out.append(c)
    return out

ZH = symbols_of("bqfh1") + symbols_of("bqfh2")      # 中文符号 96 个
EN = symbols_of("bqfh3")                            # 英文符号 28 个
W7 = 14.28

def nav_row():
    return [K(click="Keyboard_default", width=17, key_text_size="14", key_back_color="benter", key_text_color="tenter"),
            K(label="中文", click="Keyboard_bqsy1", width=16.5, key_text_size="14", key_back_color="benter", key_text_color="tenter"),
            K(label="英文", click="Keyboard_bqsy2", width=16.5, key_text_size="14", key_back_color="bgn", key_text_color="tgn"),
            K(label="表情", click="Keyboard_bqsy3", width=16.5, key_text_size="14", key_back_color="bgn", key_text_color="tgn"),
            K(label="颜文", click="Keyboard_bqsy4", width=16.5, key_text_size="14", key_back_color="bgn", key_text_color="tgn"),
            K(click="BackSpace", width=17, key_text_size="14", key_back_color="benter", key_text_color="tenter")]

def sym(c): return K(click=c)

def zh_pages():
    pages, rest = [], list(ZH)
    n = 4
    for i in range(1, n + 1):
        first, last = i == 1, i == n
        slots_tail = []                                    # 第 4 行末尾三格：上页 下页 更多（首/末页缺的那个换成符号）
        keys = []
        take = lambda m: [rest.pop(0) for _ in range(min(m, len(rest)))]
        body = take(21 + 4)                                # 前 3 行 + 第 4 行前 4 格
        keys += [sym(c) for c in body[:21]] + [sym(c) for c in body[21:]]
        pad = 25 - len(body)
        keys += [spacer(W7)] * pad
        keys.append(sym(take(1)[0]) if first and rest else (K(click=f"Keyboard_fhp{i-1}", width=W7, key_text_size="14") if not first else spacer(W7)))
        keys.append(sym(take(1)[0]) if last and rest else (K(click=f"Keyboard_fhn{i+1}", width=W7, key_text_size="14") if not last else spacer(W7)))
        keys.append(K(label="更多", click="Keyboard_symbols", width=W7, key_text_size="14", key_back_color="bgn", key_text_color="tgn"))
        pages.append((f"fh{i}", f"符号 {i}/{n}", keys + nav_row()))
    assert not rest, f"符号放不下：剩 {len(rest)} 个"
    return pages

def en_page():
    return ("fhe", "英文符号", [sym(c) for c in EN] + nav_row())

# ---------------------------------------------------------------- 原九宫格数字键盘（从原 number 原样搬过来，改名 numpad）
def numpad():
    return pk["number"]["keys"]

patch = {}
patch["style/keyboard_height"] = 225          # 键盘整体矮约 1/10
patch["style/keyboard_height_land"] = 180
patch["style/enter_labels/default"] = ICON_ENTER
# 预设按键：图标/标签/跳转。放在预设里（而不是按键上的 label），英文模式下也生效
patch["preset_keys/Shift_L/label"] = ICON_SHIFT
patch["preset_keys/BackSpace/label"] = ICON_BS
patch["preset_keys/BackSpace2/label"] = ICON_BS
patch["preset_keys/Keyboard_number/label"] = "?123"
# 空格键标签：中文模式用按键自己的 label（拼音），英文模式用预设标签（English）——Trime 的规则是按键 label 只在中文模式生效
patch["preset_keys/space/label"] = "English"
patch["preset_keys/Keyboard_emoji"] = {"label": ICON_EMOJI, "functional": False, "send": "Eisu_toggle", "select": "bqrw1"}
patch["preset_keys/Keyboard_numpad"] = {"label": "1234", "functional": False, "send": "Eisu_toggle", "select": "numpad"}
patch["preset_keys/Keyboard_fh"] = {"label": "=\\<", "functional": True, "send": "Eisu_toggle", "select": "fh1"}
# 其他键盘里的「中文/英文/⌘」入口改到新的符号页
patch["preset_keys/Keyboard_bqsy1/select"] = "fh1"
patch["preset_keys/Keyboard_bqsy2/select"] = "fhe"
patch["preset_keys/Keyboard_bqfh/select"] = "fh1"
patch["preset_keys/Keyboard_bqrw/select"] = "fh1"
for i in range(1, 5):
    patch[f"preset_keys/Keyboard_fhp{i}"] = {"label": "上页", "functional": False, "send": "Eisu_toggle", "select": f"fh{i}", "key_text_size": "14"}
    patch[f"preset_keys/Keyboard_fhn{i}"] = {"label": "下页", "functional": False, "send": "Eisu_toggle", "select": f"fh{i}", "key_text_size": "14"}

# 表情页里 ☺（U+263A）没带表情样式选择符，被系统用别的字体画成大号：补上 U+FE0F，和其他 emoji 用同一个字体
_bqrw1 = pk["bqrw1"]["keys"]
_idx = [i for i, k in enumerate(_bqrw1) if k.get("click") == "\u263a"]
assert len(_idx) == 1, _idx
patch[f"preset_keyboards/bqrw1/keys/@{_idx[0]}/click"] = "\u263a\ufe0f"
patch["preset_keyboards/default/keys"] = letters()
patch["preset_keyboards/number"] = {"author": "GBoard 风格", "name": "数字符号页", "width": 10, "ascii_mode": 1, "keys": number_page()}
patch["preset_keyboards/numpad"] = {"author": "暖暖", "name": "数字+", "width": 16.6, "ascii_mode": 1, "keys": numpad()}
for kid, name, keys in zh_pages() + [en_page()]:
    patch[f"preset_keyboards/{kid}"] = {"author": "GBoard 风格（符号取自 风花絮 的原键盘）", "name": name, "ascii_mode": 0, "width": W7, "height": 30, "keys": keys}

header = ("# 同文风主题（tongwenfeng）的布局补丁：改成 GBoard 的习惯布局。由 gen_tongwenfeng_patch.py 生成，不要手改。\n"
          "# 文件名必须是 <主题 id>.custom.yaml（主题 id = tongwenfeng.trime），Trime/librime 按这个名字自动套用。\n")
class D(yaml.SafeDumper): pass
D.add_representer(str, lambda d, s: d.represent_scalar("tag:yaml.org,2002:str", s, style="'" if (s.strip() != s or not s or s[0] in "{[&*!|>%@`#,?:-'\"" or ": " in s or " #" in s) else None))
with open(OUT, "w", encoding="utf-8") as f:
    f.write(header)
    yaml.dump({"patch": patch}, f, Dumper=D, allow_unicode=True, sort_keys=False, default_flow_style=None, width=100000)
print("wrote", OUT)
