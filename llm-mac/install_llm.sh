#!/bin/bash
# 把 AI 重排需要的二进制和模型放进 Squirrel 用户目录。Lua 与配置由仓库根目录的 ./install.sh 安装。
# 用法：llm-mac/install_llm.sh [rime_llm.so 路径] [模型路径]
set -euo pipefail

DEST="${RIME_DIR:-$HOME/Library/Rime}"
SO="${1:-$HOME/Documents/rime-llm-mac-port/build/rime_llm.so}"
MODEL="${2:-$HOME/Documents/rime-llm-mac-port/models/Qwen3.5-0.8B-Q4_K_M.gguf}"
# Qwen3.5-0.8B-Q4_K_M.gguf（ModelScope unsloth/Qwen3.5-0.8B-GGUF）；与 Windows 侧使用的文件哈希一致
EXPECT_SHA="bd258782e35f7f458f8aced1adc053e6e92e89bc735ba3be89d38a06121dc517"

[[ -f "$SO" ]] || { echo "找不到 $SO，请先按 llm-mac/README.md 构建"; exit 1; }
[[ -f "$MODEL" ]] || { echo "找不到模型 $MODEL"; exit 1; }

# 只放行 Mach-O arm64 的 Lua 模块
file "$SO" | grep -q "Mach-O 64-bit bundle arm64" || { echo "$SO 不是 arm64 的 Mach-O bundle"; exit 1; }

mkdir -p "$DEST/lua"
# 重要：不要原地覆盖已存在的 .so！macOS 会缓存旧文件的代码签名，覆盖后加载会被内核以
# "Code Signature Invalid (Invalid Page)" 直接 SIGKILL，输入法一启动就崩，系统随后会把它从已启用列表里移除。
# 所以先退出输入法，删掉旧文件，再以新文件（新 inode）的方式复制并重新签名。
"/Library/Input Methods/Squirrel.app/Contents/MacOS/Squirrel" --quit 2>/dev/null || true
sleep 1
rm -f "$DEST/lua/rime_llm.so"
cp "$SO" "$DEST/lua/rime_llm.so"
codesign --force --sign - "$DEST/lua/rime_llm.so" 2>/dev/null
codesign -v "$DEST/lua/rime_llm.so"
echo "已安装 $DEST/lua/rime_llm.so"

TARGET="$DEST/$(basename "$MODEL")"
if [[ -f "$TARGET" ]]; then
  echo "模型已存在：$TARGET（跳过）"
else
  ACTUAL="$(shasum -a 256 "$MODEL" | awk '{print $1}')"
  [[ "$ACTUAL" == "$EXPECT_SHA" ]] || { echo "模型 SHA-256 不匹配：$ACTUAL"; exit 1; }
  cp "$MODEL" "$TARGET"
  echo "已复制模型到 $TARGET"
fi
echo "完成。重启输入法后生效；AI 重排默认开启，Control+Shift+5 可在当前输入框临时开关。"
