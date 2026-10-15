<h1 align="center">Rime Ice · 1zumiii Edition</h1>

<p align="center"><a href="README.md">简体中文</a> · English</p>

<p align="center">
  A personal custom fork of <a href="https://github.com/iDvel/rime-ice">rime-ice</a> (雾凇拼音): recent-first ranking, local-LLM candidate reranking, a grammar model, fuzzy pinyin, plus configs for Squirrel (macOS), Weasel (Windows) and Trime (Android).<br>
  The original upstream README is kept as <a href="README.upstream.md">README.upstream.md</a> (Chinese).
</p>

---

## About

This fork is based on [iDvel/rime-ice](https://github.com/iDvel/rime-ice) at `da1fbe6` (2026-10-05). I use and test it mainly on macOS with Squirrel 1.1.2 (librime 1.16). A Windows (Weasel) setup is included but has seen much less verification. On Android I use it daily on one phone (ASUS Zenfone 10) with Trime; see below.

- The default branch is `custom`. It only merges updates from upstream; nothing is pushed or proposed back. `main` mirrors upstream and exists only for syncing.
- **Every personal change lives in its own file** (`*.custom.yaml` patches and standalone Lua scripts). Upstream schemas, dictionaries and Lua files are not edited, so merging upstream rarely conflicts.
- This is for personal use, not a general distribution. The AI reranking is **experimental** and was only checked on a small number of test cases.

## What's added

### Recent-first ranking

Words committed in the last 72 hours are promoted to the 2nd candidate position (at most 2 words); pinned words stay on top. Parameters (`window_hours`, `idx`, `max_boost`, …) are in `rime_ice.custom.yaml`.

- Records go to `~/Library/Rime/recent_words.tsv`, **a plain-text log of the words you commit** (up to 3000 entries). It is neither synced nor committed to the repo.
- Rime's own userdb frequency learning still applies; this sits on top of it.

### AI reranking (experimental, macOS Apple Silicon; Android in the next section)

A small local model (Qwen3.5-0.8B, Q4_K_M) reorders candidates using **what you just committed in the current input session**. After committing "我最近没有太多", typing `jingli` ranks "精力" first instead of "经理"; for four-character input such as `jingliguolai`, a two-stage pass composes "经理过来".

- Ported from [zhanghaozhecn/rime-llm-rerank](https://github.com/zhanghaozhecn/rime-llm-rerank) (attribution licence; the original is Windows-only). The C++ inference core is unchanged; the Windows cursor-context reader is removed, and the Lua layer is adapted to rime-ice's candidate structure and to Squirrel. See [llm-mac/README.md](llm-mac/README.md) (Chinese).
- **Markers**: `◇` after a reranked first candidate; `◈` after a first candidate composed by the two-stage pass.
- **Switch**: on by default, per input field (Squirrel gives every field its own session). `Control+Shift+5` toggles it for the current field. To turn it off by default, set `reset: 0` on the `ai_rerank` switch in `rime_ice.custom.yaml`.
- **Context comes only from Rime's `commit_history`**, i.e. text committed through the IME in this session. It never reads text from any app, so the first word after switching fields is not reranked.
- **Privacy**: no file containing your input is written and there is no network access. Upstream's training log, event log and frequency persistence were removed.
- **It never blocks typing for a rerank**: scoring does not wait for the background pre-decode; if the context is not pre-decoded yet, that keystroke keeps Rime's order and the next one is reranked. While you backspace (input gets shorter) the expensive second stage is skipped, and the first stage is cached by "context + candidates", so typing the letters of one word does not re-run inference.
- By default it only triggers for inputs of 3+ letters (`code_pattern: [a-z]{3,}`), leaving pinned words and abbreviations alone, and only looks at the first 80 candidates; the rest stay lazily generated so rime-ice's large dictionary doesn't stall.
- **Idle unload**: after 20 minutes without typing the model is released (~320 MB back); it reloads transparently on the next keystroke (~1 s, no rerank meanwhile). While you type continuously it is a no-op. `idle_unload_minutes: 0` turns it off.
- **Optional Metal GPU inference**: build with `-DRIME_LLM_METAL=ON`. Measured: ~27 ms → ~13 ms per scoring call, ~97% less CPU time, ~45 MB more memory; see [llm-mac/README.md](llm-mac/README.md).
- **Cost** (Apple Silicon, CPU inference, 4 threads): ~1 s model load, ~27 ms per scoring call, ~394 MB resident in Squirrel. llama.cpp's weight repacking is disabled (`use_extra_bufts = false`), which cut memory from 869 MB to 374 MB at the price of ~7 ms per call.
- **Limits**: validated on only a dozen homophone cases, so it says little about real-world accuracy. It only reorders candidates Rime already produced; it cannot create new ones.

You need to build `rime_llm.so` yourself (Xcode, CMake) and download a ~508 MB model; see [llm-mac/README.md](llm-mac/README.md).

### Android (Trime)

The same config and the AI reranker are ported to the phone. Inference runs in a separate resident process and Trime only holds a thin client, so the input method being killed or crashing does not take the model down with it. Design, measurements and the file list are in [llm-android/README.md](llm-android/README.md) (Chinese).

- **Patched Trime.** One patch on a pinned upstream commit ([patch](llm-android/trime/patches/0001-ai-rerank-daemon.patch)): an `INTERNET` permission (only used for 127.0.0.1), screen on/off notifications, an `● AI` status badge in the toolbar, and starting the daemon through Shizuku. You must build and sign it yourself (`llm-android/trime/build_apk.sh`); no APK is in the repo.
- **Resident process `rimellmd`.** A standalone binary started by adb or Shizuku as the shell user. A supervisor watches the worker and restarts it with back-off if it is killed, crashes or stops responding, recording the reason. Traffic is 127.0.0.1 plus a random token, every I/O call has a deadline, and if the daemon is unreachable the keystroke just isn't reranked, so typing is never slowed. The engine is the same one tested on the Mac.
- **Manual on/off.** Tap the `● AI` badge to switch AI on or off (green = online, yellow = loading or restarting, grey = off, red = offline, tap to start it through Shizuku); long-press for memory, latency, restart count and the last exit reason. Turning it off unloads the model at once and leaves only an idle process; turning it on loads at once. **No automatic unloading**, **off by default on a fresh install**, and the choice is remembered.
- **Phone tuning** (measured on a Snapdragon 8 Gen 2): 2 inference threads (4 caused occasional multi-second stalls from busy-waiting), 3 candidates (about a third faster than 5), 6 context tokens, and the two-stage live decoding switched off. These live only in `llm-android/trime/*.overlay.yaml` and are appended at deploy time, so macOS and Windows are unaffected.
- **GBoard-style layout.** The Tongwenfeng theme is rearranged to GBoard's main page, `?123` number/symbol page and a symbol page of 4 rows × 7 columns, with line icons, and the space bar shows 拼音 in Chinese mode and English in English mode. The patch is generated from the theme source by [gen_tongwenfeng_patch.py](llm-android/trime/gen_tongwenfeng_patch.py).
- **Verified on one phone only**; other devices and Trime versions are untested. After a reboot Shizuku has to be started before the daemon can be launched.

### Grammar model

Configured with the Wanxiang grammar model `wanxiang-lts-zh-hans.gram` (~379 MB) to improve homophone choice in whole-sentence input. Squirrel bundles the octagram plugin. The model is not in the repo: download it from [amzxyz/RIME-LMDG](https://github.com/amzxyz/RIME-LMDG/releases) into `~/Library/Rime/`. Without the file, the related settings are ignored.

Whole-sentence candidates get a `❖` marker (`model_badge_filter.lua`).

### Fuzzy pinyin

Flat/retroflex (z/zh, c/ch, s/sh) and front/back nasal (an/ang, en/eng, in/ing) pairs are enabled in `algebra_extra.yaml`, generated by `tools/gen_typo_rules.py`. To drop a pair, comment out its lines in the script and regenerate.

The script also has an "adjacent-key typo tolerance" generator, **off by default**: in practice it swallowed inputs that mix full pinyin with abbreviations.

### Smaller changes

| Change | Notes |
| --- | --- |
| Cold-word demotion | Enables upstream's `cold_word_drop`: `Control+j` demote, `Control+x` hide, `Control+d` force-delete |
| English / custom phrase frequency | User dictionary on for `melt_eng`; `custom_phrase` switched to `tabledb` (Rime writes back to `custom_phrase.txt`) |
| Spacing in mixed CN/EN | Enables upstream's `cn_en_spacer`: `VIP中P` → `VIP 中 P` |
| 5 candidates per page | 7 pushed short words onto a second row |
| Schema list | Only `rime_ice`; other schema files remain, add them back in `default.custom.yaml`'s `schema_list` |
| Appearance | `squirrel.custom.yaml`: WeChat-keyboard colours, horizontal candidates, OpenSans |

## Pitfalls I hit

1. **Never include a patch file containing a `/+` key via `__patch`.** It replaces the whole `speller/algebra` instead of appending, which silently breaks every abbreviation input. Use `"speller/algebra/+": { __include: algebra_extra:/rules }`. `tools/verify_build.sh` checks for this before installing.
2. **Don't use `@last`**; it replaces the last item and knocks out the final `uniquifier`. Use `@before last` / `@after last`.
3. **Patch keys apply in lexical order**, so numeric `@before N` depends on earlier insertions, and each key can appear only once, so slots like `@before 0` and `@after last` can serve one component each.
4. **Replace an existing `rime_llm.so` by deleting it first.** Overwriting in place makes macOS's cached code signature disagree with the new content; the kernel then kills Squirrel at load (`SIGKILL (Code Signature Invalid)`), and after repeated crashes the system drops it from the enabled input sources. `llm-mac/install_llm.sh` does this correctly.
5. **Squirrel keeps switch state per input field**, so a switch you want always on must default to on.
6. **Never cache an engine-bound object as a module-level Lua variable.** Squirrel gives every input field/app its own engine while Lua modules are shared; a `Component.Translator(...)` stored at module level ends up used after its engine was destroyed, and `query` dereferences a dangling pointer (crash report: `ScriptTranslator::Query`). Keep it in `env`, which dies with the engine.
7. **With Metal, free the model before the process exits.** llama.cpp's Metal device object asserts in a static destructor that every buffer is released; otherwise the process aborts and Squirrel leaves a crash report on every quit.
8. **Upstream's `.gitignore` ignores `*.custom.yaml`**; this fork whitelists the ones in the root, in `windows/` and in `llm-android/trime/`.
9. **Trime is not debuggable and its data directory is `noexec`**, so a `.so` cannot be dropped in from outside; it has to go inside the APK. Changing the signing key means uninstalling the old Trime first (which wipes its data directory, so back it up).
10. **Don't use 4 inference threads on the phone.** Pre-decoding and scoring run at the same time and ggml's thread pool busy-waits; on big.LITTLE cores shared with other apps that gives occasional multi-second stalls. 2–3 threads don't, and latency is about the same (the model has sequential recurrent layers, so the latency floor does not depend on thread count).
11. **A Trime theme patch must be named `<theme id>.custom.yaml`** (`tongwenfeng.trime.custom.yaml` for Tongwenfeng), and Trime only reads the theme when the input-method service starts, so restart Trime after changing it. A key's own `label` only applies in Chinese mode; in English mode the preset label is shown, so icons must be changed in `preset_keys`.
12. **After reinstalling Trime over itself, the input-method service doesn't start until the keyboard is shown**, and a deploy broadcast sent before that is dropped. Open a text field first, then deploy.

## Build and install

### macOS (Squirrel)

```bash
git clone https://github.com/1zumiii/rime-ice-Custom.git
cd rime-ice-Custom
./install.sh            # self-check, back up to ~/Library/Rime.backup-<time>, then install (keeps userdb etc.)
```

`install.sh` never overwrites `*.userdb`, `installation.yaml`, `user.yaml`, `recent_words.tsv`, cold-word records or an existing `custom_phrase.txt`. Restart the IME afterwards (`Squirrel --quit`; macOS relaunches it on the next keystroke).

The AI-rerank binary and model are installed separately with `llm-mac/install_llm.sh`; see [llm-mac/README.md](llm-mac/README.md).

### Windows (Weasel)

`windows/` contains `install.ps1` (backs up, then installs, keeping your own `default.custom.yaml` and user data), `check_deployed.ps1` (verifies after deployment that the official spelling rules survived the patches), and a `rime_ice.custom.yaml` without the features that could clash with AI reranking. The scripts have been run on a real Windows machine and fixed (robocopy hanging on locked files, an invisible `-DryRun` listing, overwriting your own `weasel.yaml` style), but coverage is still limited; use `-DryRun` first. **After installing, click "Redeploy" in the tray icon**: `WeaselDeployer.exe /deploy` on a command line does not actually compile the schemas. The script does not copy `weasel.yaml`, so your own Weasel style is kept; put style overrides in `weasel.custom.yaml`. On Windows the AI reranker is the upstream plugin built from source with some local patches that are not in this repo; it is not the macOS port in `llm-mac/`.

### Android (Trime)

Prerequisites: the patched Trime is installed and its first-run setup is done (choose "use app-specific storage"), the phone is connected over adb, and Shizuku is installed.

```bash
llm-android/trime/build_apk.sh                       # build and sign the patched APK from source (needs JDK 17, NDK r27d, etc.; see the top of the script)
adb install -r <the generated apk>
llm-android/deploy_trime.sh --with-gram              # push the config and grammar model; show Trime's keyboard first or the deploy won't take effect
llm-android/daemon/rimellmctl.sh start               # start the daemon from the computer (or tap the red AI badge on the phone to start it through Shizuku)
```

Put the model `Qwen3.5-0.8B-Q4_K_M.gguf` in Trime's user directory (`/sdcard/Android/data/com.osfans.trime/files/rime/`). Full notes, tests and benchmark scripts are in [llm-android/README.md](llm-android/README.md) (Chinese).

## Syncing with upstream

```bash
git fetch upstream
git checkout main && git merge --ff-only upstream/main && git push origin main
git checkout custom && git merge main
```

## Where the custom code is

| Location | Contents |
| --- | --- |
| `rime_ice.custom.yaml`, `default.custom.yaml`, `squirrel.custom.yaml` | Schema, global and appearance patches |
| `algebra_extra.yaml`, `tools/gen_typo_rules.py` | Fuzzy pinyin and the (off by default) adjacent-key rules |
| `lua/recent_boost_filter.lua` | Recent-first ranking |
| `lua/ai_rerank_filter.lua`, `lua/ai_rerank_processor.lua` | AI reranking filter and processor |
| `lua/model_badge_filter.lua` | `❖` marker for sentence candidates |
| `llm-mac/` | macOS port of the AI reranker: conversion script, build config, installer, tests |
| `windows/` | Weasel setup |
| `llm-android/` | Android (Trime): resident inference process, Trime patch and build scripts, phone-only config overlays, GBoard-style layout patch, benchmarks and tests |
| `install.sh`, `tools/verify_build.sh` | Installer and pre-install self-check |

## Credits and licence

Thanks to [iDvel/rime-ice](https://github.com/iDvel/rime-ice) and its contributors; [zhanghaozhecn/rime-llm-rerank](https://github.com/zhanghaozhecn/rime-llm-rerank) (AI reranking; attribution licence, free for personal use); [amzxyz/RIME-LMDG](https://github.com/amzxyz/RIME-LMDG) (Wanxiang grammar model); [llama.cpp](https://github.com/ggml-org/llama.cpp); [osfans/trime](https://github.com/osfans/trime) (the Trime input method, GPL-3.0) and the Tongwenfeng theme author 暖暖; [Shizuku](https://github.com/RikkaApps/Shizuku); and the authors of Rime, librime-lua and librime-octagram.

This repository keeps upstream's GPL-3.0 licence, see [LICENSE](LICENSE). The model and grammar-model files follow their publishers' licences.
