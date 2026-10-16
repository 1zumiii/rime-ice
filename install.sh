#!/bin/bash
# 把本仓库覆盖安装到 Squirrel 用户目录，保留个人数据和自定义补丁。
# 用法：./install.sh [--dry-run]
# 会先备份到 ~/Library/Rime.backup-<时间>，不会删除目标目录里多出的文件。
set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"
DEST="${RIME_DIR:-$HOME/Library/Rime}"
DRY=""
[[ "${1:-}" == "--dry-run" ]] && DRY="--dry-run"

"$SRC/tools/verify_build.sh"

if [[ -z "$DRY" ]]; then
  BACKUP="$DEST.backup-$(date +%Y%m%d-%H%M%S)"
  rsync -a --exclude='*.gram' --exclude='*.gguf' --exclude='build/' "$DEST"/ "$BACKUP"/
  echo "已备份到 $BACKUP"
fi

# 排除项：用户数据（词频库、同步、安装信息）、构建产物、冷词记录、最近使用记录、仓库自身文件
rsync -av $DRY \
  --exclude='.git/' --exclude='.github/' --exclude='.gitignore' --exclude='.DS_Store' \
  --exclude='others/' --exclude='AGENTS.md' --exclude='README.md' --exclude='README.upstream.md' --exclude='LICENSE' \
  --exclude='install.sh' --exclude='tools/' --exclude='windows/' --exclude='llm-mac/' --exclude='recipe.yaml' \
  --exclude='build/' --exclude='sync/' --exclude='*.userdb/' \
  --exclude='installation.yaml' --exclude='user.yaml' \
  --exclude='recent_words.tsv' --exclude='recent_pairs.tsv' --exclude='rime_llm.so' \
  --exclude='lua/cold_word_drop/drop_words.lua' \
  --exclude='lua/cold_word_drop/hide_words.lua' \
  --exclude='lua/cold_word_drop/reduce_freq_words.lua' \
  --exclude='lua/cold_word_drop/turn_down_words.lua' \
  --exclude='custom_phrase.txt' \
  "$SRC"/ "$DEST"/

# custom_phrase.txt 启用了 tabledb，Rime 会回写它，所以只在目标不存在时才复制
[[ -e "$DEST/custom_phrase.txt" ]] || { [[ -n "$DRY" ]] || cp "$SRC/custom_phrase.txt" "$DEST/"; }

# 旧版 rime.lua（手动 require 的写法）已被 lua_xxx@*name 取代，挪走避免重复加载
if [[ -e "$DEST/rime.lua" && ! -e "$SRC/rime.lua" ]]; then
  if [[ -z "$DRY" ]]; then mv "$DEST/rime.lua" "$DEST/rime.lua.old"; fi
  echo "旧 rime.lua 已改名为 rime.lua.old"
fi

echo "完成。重新部署：\"/Library/Input Methods/Squirrel.app/Contents/MacOS/Squirrel\" --reload"
