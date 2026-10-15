#!/bin/bash
# 安装前自检：在临时目录编译，确认补丁没有把官方的拼写规则（尤其是简拼 abbrev）覆盖掉。
# 用法：tools/verify_build.sh   （通过返回 0）
set -euo pipefail
SRC="$(cd "$(dirname "$0")/.." && pwd)"
SHARED="/Library/Input Methods/Squirrel.app/Contents/SharedSupport"
DEPLOYER="/Library/Input Methods/Squirrel.app/Contents/MacOS/rime_deployer"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

rsync -a --exclude='.git/' --exclude='others/' --exclude='build/' --exclude='*.userdb/' "$SRC"/ "$TMP"/
"$DEPLOYER" --build "$TMP" "$SHARED" "$TMP/build" >/dev/null 2>&1 || { echo "自检失败：编译出错"; exit 1; }

SCHEMA="$TMP/build/rime_ice.schema.yaml"
OFFICIAL=$(git -C "$SRC" show upstream/main:rime_ice.schema.yaml 2>/dev/null \
  | awk '/^  algebra:/{f=1;next} f&&/^  [a-z_]/{exit} f&&/^    - /' | wc -l | tr -d ' ')
BUILT=$(awk '/^  algebra:/{f=1;next} f&&/^  [a-z_]/{exit} f&&/^    - /' "$SCHEMA" | wc -l | tr -d ' ')
ABBREV=$(grep -c '"abbrev/' "$SCHEMA" || true)

if [[ "$ABBREV" -lt 2 || "$BUILT" -lt "$OFFICIAL" ]]; then
  echo "自检失败：官方拼写规则被覆盖（官方 $OFFICIAL 条，编译后 $BUILT 条，abbrev $ABBREV 条）"
  exit 1
fi
echo "自检通过：拼写规则 $BUILT 条（官方 $OFFICIAL 条），abbrev $ABBREV 条"
