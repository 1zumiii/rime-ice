#!/usr/bin/env python3
"""用 ctypes 直接调 librime，给拼音输入跑候选，比较有无「内置纠错」时的效果。
用法：python3 rime_probe.py <工作目录> <方案变体：base|correction> <输入文件，每行一个输入>  输出 JSON 行：输入、前 7 个候选
只依赖 Squirrel 自带的 librime 和仓库的词库，不加载 Lua 组件。"""
import ctypes, json, os, re, shutil, subprocess, sys
from ctypes import c_int, c_char_p, c_void_p, c_size_t, POINTER, Structure

LIB = "/Library/Input Methods/Squirrel.app/Contents/Frameworks/librime.1.dylib"
SHARED = "/Library/Input Methods/Squirrel.app/Contents/SharedSupport"
REPO = "/Users/izumi/Documents/RimeCustomised"


class Traits(Structure):
    _fields_ = [("data_size", c_int), ("shared_data_dir", c_char_p), ("user_data_dir", c_char_p),
                ("distribution_name", c_char_p), ("distribution_code_name", c_char_p),
                ("distribution_version", c_char_p), ("app_name", c_char_p), ("modules", c_void_p),
                ("min_log_level", c_int), ("log_dir", c_char_p), ("prebuilt_data_dir", c_char_p),
                ("staging_dir", c_char_p)]


class Cand(Structure):
    _fields_ = [("text", c_char_p), ("comment", c_char_p), ("reserved", c_void_p)]


class Comp(Structure):
    _fields_ = [("length", c_int), ("cursor_pos", c_int), ("sel_start", c_int), ("sel_end", c_int), ("preedit", c_char_p)]


class Menu(Structure):
    _fields_ = [("page_size", c_int), ("page_no", c_int), ("is_last_page", c_int), ("highlighted", c_int),
                ("num_candidates", c_int), ("candidates", POINTER(Cand)), ("select_keys", c_char_p)]


class Ctx(Structure):
    _fields_ = [("data_size", c_int), ("composition", Comp), ("menu", Menu), ("commit_text_preview", c_char_p),
                ("select_labels", c_void_p)]


def prepare_dir(work, variant):
    user = os.path.join(work, "user")
    if os.path.exists(user) and os.path.exists(os.path.join(user, ".ready-" + variant)):
        return user
    shutil.rmtree(user, ignore_errors=True)
    os.makedirs(user)
    for name in ["default.yaml", "rime_ice.schema.yaml", "rime_ice.dict.yaml", "symbols_v.yaml", "symbols_caps_v.yaml",
                 "cn_dicts", "en_dicts", "opencc", "melt_eng.schema.yaml", "melt_eng.dict.yaml", "radical_pinyin.schema.yaml",
                 "radical_pinyin.dict.yaml", "algebra_extra.yaml", "custom_phrase.txt", "symbols.yaml", "t9.schema.yaml"]:
        src = os.path.join(REPO, name)
        if os.path.exists(src):
            (shutil.copytree if os.path.isdir(src) else shutil.copy)(src, os.path.join(user, name))
    # 去掉 Lua 组件和语法模型（探针不加载 Lua 插件，也不需要 gram）
    p = os.path.join(user, "rime_ice.schema.yaml")
    s = open(p, encoding="utf-8").read()
    s = "\n".join(l for l in s.split("\n") if not re.match(r"^\s*-\s*lua_(translator|filter|processor)@", l))
    s = re.sub(r"\n\s*grammar:\n(\s+.*\n)+", "\n", s) if "grammar:" in s else s
    open(p, "w", encoding="utf-8").write(s)
    # 方案补丁：沿用线上配置里的模糊音规则；变体 correction 打开内置纠错
    patch = ["patch:", '  "speller/algebra/+":', "    __include: algebra_extra:/rules"]
    if variant == "correction":
        patch.append("  translator/enable_correction: true")
    if variant.startswith("nb"):
        shutil.copy("/tmp/claude-501/probe/alg_%s.yaml" % variant.split("+")[0], os.path.join(user, "algebra_extra.yaml"))
        if variant.endswith("+corr"):
            patch.append("  translator/enable_correction: true")
    if variant == "neighbour":      # 旧做法：用 derive 规则生成邻键拼写（没有惩罚）
        shutil.copy("/tmp/claude-501/probe/algebra_neighbour.yaml", os.path.join(user, "algebra_extra.yaml"))
    open(os.path.join(user, "rime_ice.custom.yaml"), "w", encoding="utf-8").write("\n".join(patch) + "\n")
    open(os.path.join(user, "default.custom.yaml"), "w", encoding="utf-8").write(
        "patch:\n  schema_list:\n    - schema: rime_ice\n  menu/page_size: 40\n")
    open(os.path.join(user, ".ready-" + variant), "w").close()
    return user


def main():
    work, variant, infile = sys.argv[1], sys.argv[2], sys.argv[3]
    os.makedirs(work, exist_ok=True)
    user = prepare_dir(work, variant)
    lib = ctypes.CDLL(LIB)
    lib.rime_get_api.restype = c_void_p
    api = lib.rime_get_api()

    def fn(idx, restype, *argtypes):
        addr = c_void_p.from_address(api + 8 + 8 * idx).value
        return ctypes.CFUNCTYPE(restype, *argtypes)(addr)

    setup, initialize, finalize = fn(0, None, POINTER(Traits)), fn(2, None, POINTER(Traits)), fn(3, None)
    start_maint, join_maint = fn(4, c_int, c_int), fn(6, None)
    create_session, destroy_session = fn(13, c_size_t), fn(15, c_int, c_size_t)
    clear_comp, get_context, free_context = fn(20, None, c_size_t), fn(23, c_int, c_size_t, POINTER(Ctx)), fn(24, c_int, POINTER(Ctx))
    select_schema, simulate = fn(34, c_int, c_size_t, c_char_p), fn(47, c_int, c_size_t, c_char_p)

    tr = Traits()
    tr.data_size = ctypes.sizeof(Traits) - ctypes.sizeof(c_int)
    tr.shared_data_dir, tr.user_data_dir = SHARED.encode(), user.encode()
    tr.distribution_name = b"probe"; tr.distribution_code_name = b"probe"; tr.distribution_version = b"0"
    tr.app_name = b"rime.probe"; tr.min_log_level = 2
    tr.log_dir = os.path.join(work, "log").encode()
    os.makedirs(os.path.join(work, "log"), exist_ok=True)
    setup(ctypes.byref(tr))
    initialize(ctypes.byref(tr))
    start_maint(1)
    join_maint()
    sid = create_session()
    select_schema(sid, b"rime_ice")
    out = open(infile + "." + variant + ".jsonl", "w", encoding="utf-8")
    for line in open(infile, encoding="utf-8"):
        inp = line.strip()
        if not inp:
            continue
        clear_comp(sid)
        simulate(sid, inp.encode())
        ctx = Ctx(); ctx.data_size = ctypes.sizeof(Ctx) - ctypes.sizeof(c_int)
        cands = []; comms = []
        if get_context(sid, ctypes.byref(ctx)):
            for i in range(ctx.menu.num_candidates):
                c = ctx.menu.candidates[i]
                cands.append((c.text or b"").decode("utf-8", "replace")); comms.append((c.comment or b"").decode("utf-8", "replace"))
            free_context(ctypes.byref(ctx))
        out.write(json.dumps({"in": inp, "c": cands, "m": comms}, ensure_ascii=False) + "\n")
    out.close()
    destroy_session(sid)
    finalize()


main()
