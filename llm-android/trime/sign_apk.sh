#!/bin/bash
# 对 Gradle 产出的未签名 Trime APK 做对齐和签名（自己的密钥，不是上游的）。
# 用法：sign_apk.sh <unsigned.apk> <输出.apk>
# 密钥库在 ~/Documents/rime-android-port/keys/dev.jks（口令在同目录 dev.pw），不进仓库；换了密钥就必须先卸载原来的 Trime。
set -euo pipefail
IN="$1"; OUT="$2"
BT="${BUILD_TOOLS:-$HOME/Library/Android/sdk/build-tools/36.0.0}"
KEYS="${KEYS:-$HOME/Documents/rime-android-port/keys}"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
"$BT/zipalign" -f -p 4 "$IN" "$TMP/aligned.apk"
PW="$(cat "$KEYS/dev.pw")"
"$BT/apksigner" sign --ks "$KEYS/dev.jks" --ks-key-alias dev --ks-pass "pass:$PW" --key-pass "pass:$PW" --out "$OUT" "$TMP/aligned.apk"
"$BT/apksigner" verify "$OUT" 2>&1 | grep -v WARNING || true
ls -l "$OUT"
