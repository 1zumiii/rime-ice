#!/bin/bash
# 把本仓库的 Rime 配置推送到手机上的 Trime（同文输入法）并触发部署。
# 前提：手机已用 adb 连接，Trime 已安装并走完首次启动引导（引导里选「使用应用专属存储空间」），部署时手机亮屏并弹出键盘（输入法服务运行时才会响应部署广播）。
# 用法：llm-android/deploy_trime.sh [--with-gram] [--dry-run]
#   --with-gram  同时推送语法模型 wanxiang-lts-zh-hans.gram（约 380 MB，默认从 ~/Library/Rime 取；已存在且大小一致则跳过）
#   --dry-run    只列出会推送的文件，不改动手机
# 环境变量：ANDROID_SERIAL 指定设备；GRAM 指定语法模型路径。
set -euo pipefail

ADB="${ADB:-adb}"
PKG=com.osfans.trime
DEST=/sdcard/Android/data/$PKG/files/rime
REPO="$(cd "$(dirname "$0")/.." && pwd)"
GRAM="${GRAM:-$HOME/Library/Rime/wanxiang-lts-zh-hans.gram}"
WITH_GRAM=0; DRY=0
for a in "$@"; do case "$a" in --with-gram) WITH_GRAM=1;; --dry-run) DRY=1;; *) echo "unknown option $a"; exit 2;; esac; done

"$ADB" get-state >/dev/null 2>&1 || { echo "没有连接的设备（adb devices）"; exit 1; }
"$ADB" shell "pm list packages $PKG" | grep -q "$PKG" || { echo "手机上没有安装 Trime"; exit 1; }
"$ADB" shell "test -d $DEST" || { echo "$DEST 不存在：请先打开 Trime 走完首次启动引导"; exit 1; }

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
# 排除：Mac/Windows 专属文件、文档、构建产物、个人数据、大文件
rsync -a --exclude='.git/' --exclude='.github/' --exclude='.gitignore' --exclude='.DS_Store' \
  --exclude='others/' --exclude='windows/' --exclude='llm-mac/' --exclude='llm-android/' --exclude='tools/' \
  --exclude='README*.md' --exclude='AGENTS.md' --exclude='LICENSE' --exclude='install.sh' --exclude='recipe.yaml' \
  --exclude='squirrel.yaml' --exclude='squirrel.custom.yaml' --exclude='weasel.yaml' \
  --exclude='build/' --exclude='*.userdb/' --exclude='*.gram' --exclude='*.gguf' --exclude='luac.out' \
  --exclude='recent_words.tsv' \
  "$REPO"/ "$STAGE"/
# 手机专属的补丁：trime/<名字>.overlay.yaml 追加到暂存区里的 <名字>.custom.yaml 末尾（仓库里的文件不改）
for ov in "$REPO"/llm-android/trime/*.overlay.yaml; do
  [[ -f "$ov" ]] || continue
  base="$(basename "$ov" .overlay.yaml)"; tgt="$STAGE/$base.custom.yaml"
  [[ -f "$tgt" ]] || { echo "跳过 $ov：没有对应的 $base.custom.yaml"; continue; }
  [[ -n "$(tail -c1 "$tgt")" ]] && echo >> "$tgt"
  cat "$ov" >> "$tgt"
done
# 新装默认关闭 AI（手机上手动启停）：改暂存文件里开关的 reset 默认值，并确认确实改到了
if [[ -f "$STAGE/rime_ice.custom.yaml" ]]; then
  sed -i '' 's/name: ai_rerank, reset: 1,/name: ai_rerank, reset: 0,/' "$STAGE/rime_ice.custom.yaml"
  grep -q 'name: ai_rerank, reset: 0,' "$STAGE/rime_ice.custom.yaml" || { echo "错误：没能把 ai_rerank 的默认值改成关闭（rime_ice.custom.yaml 里的写法变了？）"; exit 1; }
fi
echo "将推送 $(find "$STAGE" -type f | wc -l | tr -d ' ') 个文件，$(du -sh "$STAGE" | cut -f1) → $DEST"
[[ $DRY -eq 1 ]] && { find "$STAGE" -maxdepth 1 | sed "s#$STAGE/#  #" | sort | head -40; exit 0; }

# 备份手机上现有的 rime 目录（只备份一次，不覆盖旧备份）
BAK="$DEST.bak-before-ours"
"$ADB" shell "test -d $BAK || cp -r $DEST $BAK" && echo "备份：$BAK"

"$ADB" push "$STAGE"/. "$DEST"/ | tail -1
# Trime 主题补丁（键盘布局/高度）：放在 llm-android/trime/ 下，上面的同步会排除它们，逐个单独推送
for tp in "$REPO"/llm-android/trime/*.custom.yaml; do
  [[ -f "$tp" ]] && "$ADB" push "$tp" "$DEST/$(basename "$tp")" | tail -1
done

if [[ $WITH_GRAM -eq 1 ]]; then
  [[ -f "$GRAM" ]] || { echo "找不到语法模型 $GRAM"; exit 1; }
  WANT=$(stat -f%z "$GRAM"); HAVE=$("$ADB" shell "stat -c %s $DEST/$(basename "$GRAM") 2>/dev/null || echo 0" | tr -d '\r')
  if [[ "$WANT" == "$HAVE" ]]; then echo "语法模型已在手机上（大小一致），跳过"; else "$ADB" push "$GRAM" "$DEST"/ | tail -1; fi
fi

# 触发部署（Trime 自带的广播接收器）并等待编译产物。
# 注意：接收器只在输入法服务运行时才响应，也就是手机上要先弹出过键盘；否则广播被忽略，下面会一直等到超时。
if ! "$ADB" shell "pidof $PKG" | grep -q '[0-9]'; then
  echo ">>> 手机上 Trime 进程没有在运行：请在手机上打开任意输入框，把键盘弹出来，部署才会开始"
fi
"$ADB" shell "rm -f $DEST/build/rime_ice.table.bin"   # 强制重新编译词库
"$ADB" shell "am broadcast -a $PKG.action.DEPLOY -p $PKG" | tail -1
for i in $(seq 1 90); do
  sleep 2
  [[ $i -eq 8 ]] && echo ">>> 还没开始部署：请确认手机亮屏，并在任意输入框里弹出键盘（输入法服务运行时才会响应）"
  "$ADB" shell "test -f $DEST/build/rime_ice.table.bin && test -f $DEST/build/rime_ice.prism.bin" && { echo "部署完成（约 $((i*2)) 秒）"; exit 0; }
done
echo "等了 3 分钟还没有编译产物，请看 adb logcat | grep rime.trime"; exit 1
