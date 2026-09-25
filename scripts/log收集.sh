#!/bin/bash
# log收集.sh —— 「同一开机第 2 轮接管」卡点取证（2026-09-25）
# 背景：工作总结 5.36 —— 第 2 轮 desk-takeover 永久阻塞在 `ip link set wlan0 up`，
#       WiFi/蓝牙/「回到安卓」同时失灵，结局大概率强制重启。本脚本把现场留到磁盘，
#       并在终端里实时展示进度；用户确认抓够后可直接选择强制重启整机。
#
# 用法：
#   bash log收集.sh            桌面按钮入口：确保后台收集器在跑，本终端实时滚动日志；
#                             按【回车】弹出菜单：S=停止收集退出 / R=强制重启整机 /
#                             X=退出窗口(收集继续) / 回车=继续看
#   bash log收集.sh --daemon   收集器本体（入口自动脱离式拉起，不用手动跑）
#
# 为什么取证全走 adb→安卓 root（实测依据）：
#   - 容器内 kptr_restrict=2，普通用户 wchan 恒为 0；安卓侧 su root 能读到符号。
#   - 安卓与容器共享内核与 netns（方案 F21），容器进程在安卓 PID ns 全可见。
#   - emulator-5554 本地通道不经 WiFi 射频（工作总结 5.0.6），WiFi 死了取证不断。
#   - 每快照写盘即 sync：rootfs 在 /data，强制重启不丢已落盘内容。
# 红线合规：全程只读（ps/wchan/dmesg tail/ip show/iw dev/getprop）；
#   唯一的"写"动作是菜单里显式确认过的整机重启。`su -c` 内层一律双引号（5.24）。

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
umask 022

SELF=$(readlink -f "$0")
BASE_DIR=/home/xieyizhou/Documents/XiaomiPad8Pro-drm-display
LOG_DIR="${LOG_DIR:-$BASE_DIR/logs/log收集}"
LOG="$LOG_DIR/forensics.log"
TAKEOVER_LOG="${TAKEOVER_LOG:-$BASE_DIR/logs/desk-takeover.log}"
INTERVAL="${INTERVAL:-10}"
DEV="${DEV:-emulator-5554}"
DAEMON_PAT='log收集\.sh --daemon'

arc() { timeout 12 adb -s "$DEV" shell "su -c '$1'" 2>&1; }   # 安卓侧 root，整体单引号包住

# ───────────────────────────── 收集器本体 ─────────────────────────────
collector() {
  local END=$(( $(date +%s) + ${MAX_SECS:-86400} ))   # 默认最长 24h，防忘在后台
  mkdir -p "$LOG_DIR" || exit 1
  if [ -f "$LOG" ] && [ "$(stat -c %s "$LOG")" -gt 83886080 ]; then
    mv "$LOG" "$LOG_DIR/forensics-old-$(date +%m%d-%H%M%S).log" 2>/dev/null
  fi
  {
    echo "@@@@@@ 开始收集 $(date '+%m%d-%H%M%S') uid=$(id -u) uptime=$(cut -d. -f1 /proc/uptime)s"
    echo "@@@@@@ 注意：下面所有 PID 均为**安卓 PID ns 视角**（共享内核，容器进程全可见）"
    echo "@@@@@@ 卡死判据：出现「IPPID <n> ip link set wlan0 up」且该 PID 长期 3 个快照 D 态"
  } >> "$LOG" 2>/dev/null

  # 一次 adb 拿全设备视角数据（pid/状态/wchan 必须同 ns）。
  # 顺序教训（09-25 16:05 轮实锤）：rtnl 冻结时 `ip -o link`/`iw dev` 会挂死并被 12s timeout
  # 连坐截掉后面的 dmesg/计数段（那段才是找死因的关键）⇒ counts/dmesg 在前，ip/iw 垫底。
  local PAY_MAIN='echo IP-PROCS:; for p in /proc/[0-9]*; do [ -f $p/cmdline ] || continue; c=$(tr "\0" " " 2>/dev/null < $p/cmdline); case " $c" in " ip "*) echo IPPID $(basename $p) "$c";; esac; done; echo D-R-PROCS:; ps -eo pid,stat,wchan:40,args | grep -E "^[[:space:]]*[0-9]+ [DR]"; echo SF=$(getprop init.svc.surfaceflinger); echo BRIDGE=$(pgrep -x bthci-bridge | tr "\n" " "); echo HCI=$(ls /sys/class/bluetooth 2>/dev/null | tr "\n" " "); echo REC_COUNT=$(dmesg | grep -c is_driver_recovering); echo TIMEDOUT_COUNT=$(dmesg | grep -c "Driver Loading Timed-out"); dmesg | tail -400 | grep -iE "cnss|wlan|peach|btpower|cfg80211|blk: " | tail -25; echo WLAN-LINK:; ip -o -br link show wlan0; iw dev'
  while :; do
    local T=$(date '+%m%d-%H%M%S')
    local SNAP
    SNAP=$(
      echo "===== SNAPSHOT $T uptime=$(cut -d. -f1 /proc/uptime)s ====="
      if [ -f "$TAKEOVER_LOG" ]; then
        echo "TO-LOG stat: $(stat -c '%y %s' "$TAKEOVER_LOG" 2>/dev/null)"
        echo "TO-LOG tail:"; tail -c 400 "$TAKEOVER_LOG" 2>/dev/null
      else
        echo "TO-LOG: MISSING($TAKEOVER_LOG)"
      fi
      arc "$PAY_MAIN"
      local p
      for p in $(arc "for p in /proc/[0-9]*; do [ -f \$p/cmdline ] || continue; c=\$(tr \"\\0\" \" \" 2>/dev/null < \$p/cmdline); case \" \$c\" in \" ip \"*) basename \$p;; esac; done"); do
        echo "IP-DETAIL pid=$p (安卓视角):"
        arc "cat /proc/$p/wchan; echo; grep -H State /proc/$p/task/*/status 2>/dev/null; for t in /proc/$p/task/*; do echo TID \$(basename \$t) \$(cat \$t/wchan 2>/dev/null); done"
      done
    )
    printf '%s\n' "$SNAP" >> "$LOG"
    sync
    now=$(date +%s)
    [ "$now" -ge "$END" ] && { echo "@@@@@@ 收集器到达最长时限自动结束 $(date '+%m%d-%H%M%S')" >> "$LOG"; sync; break; }
    sleep "$INTERVAL"
  done
}

# ───────────────────────────── 终端交互入口 ─────────────────────────────
status_line() {   # 实时卡点判定，进度条下一行提示
  local hit
  hit=$(tail -n 300 "$LOG" 2>/dev/null | grep -E "IPPID [0-9]+ ip link set wlan0 up" | tail -1)
  if [ -n "$hit" ]; then
    echo "★★★ 已抓到卡点:[$hit] —— 若已持续 3+ 个快照，取证够了，可选 R 重启"
  else
    echo "● 未出现 [ip link set wlan0 up] 卡点（正常等待中）"
  fi
}

menu() {
  while :; do
    echo
    echo "──────── 菜单 ────────"
    echo "  回车 = 继续看收集进度"
    echo "  X    = 退出本窗口（后台收集器继续跑，之后可再点图标回来）"
    echo "  S    = 停止收集并退出"
    echo "  R    = 强制重启整个系统（= 长按电源；日志已 sync，不会丢）"
    read -r -p "选择> " ans && ans=${ans:-ENTER} || ans=ENTER
    case "$ans" in
      s|S)
        pkill -f "$DAEMON_PAT"; echo "收集器已停止 $(date '+%H:%M:%S')；日志: $LOG"; sleep 3; exit 0;;
      r|R)
        local y
        read -r -p ">> 确认立即重启整机？(输入 yes) " y
        if [ "$y" = "yes" ]; then
          echo "@@@@@@ 用户菜单选择重启 $(date '+%m%d-%H%M%S')" >> "$LOG"
          sync
          pkill -f "$DAEMON_PAT" 2>/dev/null
          echo "正在重启…"
          timeout 15 adb -s "$DEV" reboot 2>&1 || arc "reboot"
          sleep 5
        else
          echo "已取消重启"
        fi;;
      x|X)
        echo "窗口退出；后台收集器继续跑（再点图标可回来查看/操作）"; exit 0;;
      *)
        return;;   # 回车 → 回到进度
    esac
  done
}

entry() {
  mkdir -p "$LOG_DIR"
  if pgrep -f "$DAEMON_PAT" >/dev/null; then
    echo "收集器已在跑（pid $(pgrep -f "$DAEMON_PAT" | tr '\n' ' ')），进入进度查看"
  else
    setsid nohup bash "$SELF" --daemon >/dev/null 2>&1 </dev/null &
    sleep 2
    if pgrep -f "$DAEMON_PAT" >/dev/null; then
      echo "后台收集器已启动（pid $(pgrep -f "$DAEMON_PAT")，每 ${INTERVAL}s 一个快照，写盘即 sync）"
    else
      echo "!! 收集器启动失败，检查 $LOG_DIR 权限后重试"; sleep 8; exit 1
    fi
  fi
  echo "日志文件: $LOG"
  echo "进 Linux 前保持本窗口开着即可；随时按【回车】打开菜单"
  echo
  local OFF=0
  while :; do
    if [ -f "$LOG" ]; then
      local SZ; SZ=$(stat -c %s "$LOG")
      [ "$SZ" -lt "$OFF" ] && OFF=0   # 滚动换文件
      if [ "$SZ" -gt "$OFF" ]; then
        tail -c +"$((OFF + 1))" "$LOG"
        OFF=$SZ
      fi
    fi
    status_line
    if [ -t 0 ]; then
      IFS= read -r -t "$INTERVAL" key; rc=$?
      [ "$rc" -eq 0 ] && menu
      [ "$rc" -eq 1 ] && sleep "$INTERVAL"   # stdin EOF：防 busy loop
    else
      sleep "$INTERVAL"   # 非终端环境（自动化测试）：只滚动不看键
    fi
  done
}

case "$1" in
  --daemon) collector ;;
  *)        entry ;;
esac
