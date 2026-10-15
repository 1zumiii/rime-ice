#!/bin/bash
# 在手机上部署、启动、停止 AI 重排守护进程 rimellmd（shell 身份，经 adb；重启手机后需要重新 start）。
# 用法：llm-android/daemon/rimellmctl.sh <deploy|start|stop|restart|status|log> [选项]
#   deploy   推送二进制和模型到 /data/local/tmp/rimellm/（模型大小一致则跳过）
#   start    （必要时先 deploy）以「监督进程 + 工作进程」方式启动；已在运行则不重复启动
#   stop     停止（先终止监督进程，它会带走工作进程）
#   status   进程、状态文件、最近日志
#   log      最近 40 行日志
# 环境变量：ADB、BIN（rimellmd 路径，默认 ~/Documents/rime-android-port/build_host/rimellmd）、MODEL（gguf 路径）、
#          THREADS（默认 2：实测 4 线程会因预解码和打分同时忙等而出现数秒卡顿，2~3 线程没有）、IDLE_SEC（空闲自动卸载秒数，默认 0 = 不自动卸载，靠手动启停）、SCREEN_OFF_SEC（熄屏后单独的时限，默认 0 = 不单独设）
set -euo pipefail

ADB="${ADB:-adb}"
PKG=com.osfans.trime
RIME_DIR=/sdcard/Android/data/$PKG/files/rime
DIR=/data/local/tmp/rimellm
BIN="${BIN:-$HOME/Documents/rime-android-port/build_host/rimellmd}"
MODEL="${MODEL:-$HOME/Documents/rime-llm-mac-port/models/Qwen3.5-0.8B-Q4_K_M.gguf}"
THREADS="${THREADS:-2}"
IDLE_SEC="${IDLE_SEC:-0}"
SCREEN_OFF_SEC="${SCREEN_OFF_SEC:-0}"
PORT="${PORT:-17920}"
N_CTX="${N_CTX:-96}"         # 引擎默认 128；96 够 6 个并发序列（实测堆内存 374→234 MB，延迟不变）
N_SEQ_MAX="${N_SEQ_MAX:-6}"  # 引擎默认 12；= 1（模板）+ 最多 5 个候选

sh_() { "$ADB" shell "$@" | tr -d '\r'; }
pids() { sh_ "pidof rimellmd" || true; }

cmd_deploy() {
  [[ -f "$BIN" ]] || { echo "找不到 $BIN（先构建 rimellmd）"; exit 1; }
  sh_ "mkdir -p $DIR"
  # 二进制：先停掉再替换（运行中的可执行文件不能被覆盖）
  [[ -n "$(pids)" ]] && cmd_stop
  local tmp; tmp=$(mktemp); llvm_strip "$BIN" "$tmp" 2>/dev/null || cp "$BIN" "$tmp"
  "$ADB" push "$tmp" $DIR/rimellmd | tail -1; rm -f "$tmp"
  sh_ "chmod 755 $DIR/rimellmd"
  local want have
  want=$(stat -f%z "$MODEL"); have=$(sh_ "stat -c %s $DIR/model.gguf 2>/dev/null || echo 0")
  if [[ "$want" == "$have" ]]; then echo "模型已在手机上（大小一致），跳过"; else "$ADB" push "$MODEL" $DIR/model.gguf | tail -1; fi
}

llvm_strip() {
  local s="$HOME/Documents/rime-android-port/ndk/android-ndk-r27d/toolchains/llvm/prebuilt/darwin-x86_64/bin/llvm-strip"
  [[ -x "$s" ]] && "$s" --strip-unneeded -o "$2" "$1"
}

cmd_start() {
  if [[ -n "$(pids)" ]]; then echo "已在运行：$(pids)"; return 0; fi
  sh_ "test -x $DIR/rimellmd && test -f $DIR/model.gguf" 2>/dev/null || cmd_deploy
  sh_ "test -d $RIME_DIR" || { echo "$RIME_DIR 不存在：先打开 Trime 走完首次引导"; exit 1; }
  # 日志轮转：超过 1 MB 就留一份旧的
  sh_ "[ \$(stat -c %s $DIR/daemon.log 2>/dev/null || echo 0) -gt 1048576 ] && mv $DIR/daemon.log $DIR/daemon.log.1 || true"
  # 整个启动命令放在子 shell 里并重定向全部输出，否则 adb shell 会一直等后台进程释放管道
  "$ADB" shell "( cd $DIR && setsid nohup ./rimellmd --supervise --model $DIR/model.gguf --rime-dir $RIME_DIR \
      --log-dir $DIR --port $PORT --threads $THREADS --idle-sec $IDLE_SEC --screen-off-sec $SCREEN_OFF_SEC --n-ctx $N_CTX --n-seq-max $N_SEQ_MAX \
      >> $DIR/daemon.log 2>&1 < /dev/null & ) > /dev/null 2>&1 < /dev/null" || true
  for _ in $(seq 1 20); do sleep 0.5; sh_ "test -f $RIME_DIR/llm_token" && [[ -n "$(pids)" ]] && break; done
  [[ -n "$(pids)" ]] && echo "已启动：$(pids | tr '\n' ' ')" || { echo "启动失败，见 log"; cmd_log; exit 1; }
}

cmd_stop() {
  local p; p=$(pids)
  [[ -z "$p" ]] && { echo "没有在运行"; return 0; }
  # pidof 的顺序不保证；监督进程是父进程。先给所有 rimellmd 发 SIGTERM（监督进程收到会带走子进程）
  for x in $p; do sh_ "kill $x" || true; done
  for _ in $(seq 1 20); do sleep 0.5; [[ -z "$(pids)" ]] && { echo "已停止"; return 0; }; done
  for x in $(pids); do sh_ "kill -9 $x" || true; done; echo "已强制停止"
}

cmd_status() {
  echo "进程：$(pids | tr '\n' ' ')"
  sh_ "ls -l $DIR 2>/dev/null | awk '{print \$5, \$8, \$9}'" | head -8
  echo "--- ai_status.json"; sh_ "cat $RIME_DIR/ai_status.json 2>/dev/null" ; echo
  echo "--- 日志（最后 8 行）"; sh_ "tail -8 $DIR/daemon.log 2>/dev/null"
}
cmd_log() { sh_ "tail -40 $DIR/daemon.log 2>/dev/null"; }

case "${1:-}" in
  deploy) cmd_deploy ;;
  start) cmd_start ;;
  stop) cmd_stop ;;
  restart) cmd_stop; cmd_start ;;
  status) cmd_status ;;
  log) cmd_log ;;
  *) sed -n 2,12p "$0"; exit 2 ;;
esac
