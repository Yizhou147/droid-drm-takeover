#!/bin/bash
# bt-power-watcher.sh — 抓"谁在收蓝牙芯片电源"的沿触发取证器（只读）。
# 跑法：bash bt-power-watcher.sh [总秒=1800] [本地采样间隔秒=2]
#
# 设计要点（都是这两晚踩出来的）：
#   1. **本地高频采样，不走 adb**：`/sys/class/rfkill/*/soft`（bt_power 与 hci0）从容器里直接可读，
#      2s 一拍零成本。反过来若每拍都 adb 轮询，adb 自身的 binder/网络活动会把安卓从 idle 里
#      拎出来 —— 我们想看的"HAL 空闲收电源"就永远不发生（观测者效应，09-30 差点栽在这）。
#   2. **贵的东西只在沿上做**：soft 一翻转，才去抓 logcat/dmesg/dumpsys 那一刻的现场。
#      事后 `logcat -d` 拿的是缓冲区尾部，所以沿后要**立刻**抓，晚几秒就被后续日志挤出窗口。
#   3. hciconfig/bluez 也进同一时间轴：分清"芯片断电(bt_power)"、"适配器 DOWN(hci0)"、
#      "bluez Powered: no"这三件事的先后顺序 —— 上一版把三者混成一句话，误判了一整晚。
#   4. 绝不动作：不写 rfkill、不 unblock、不重启服务、不碰桥（电源协调归 btpower/HAL，红线）。
DEV=$(adb devices | awk '$2=="device"{print $1; exit}')
[ -n "$DEV" ] || { echo "NO-ADB（沿上就没法抓 logcat/dmesg 了）"; }
R=${1:-1800}
IV=${2:-2}
# 自定位：仓库同级 logs（原来写死 /home/xieyizhou/…，换用户名就写不到地方）
ROOT=${ROOT:-$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)}
OUT=${OUT:-$(dirname "$ROOT")/logs/bt-power-watch-$(date +%m%d-%H%M%S).log}
run() { [ -n "$DEV" ] && timeout 10 adb -s "$DEV" shell "su -c '$1'" 2>&1 | tr -d '\r'; }
rf() {   # rf() <name> → soft/hard
    local f
    for f in /sys/class/rfkill/rfkill*; do
        [ "$(cat $f/name 2>/dev/null)" = "$1" ] && { echo "$(cat $f/soft 2>/dev/null)-$(cat $f/hard 2>/dev/null)"; return; }
    done
    echo NOREAD
}
hci() { hciconfig hci0 2>/dev/null | awk 'NR==3' | tr -d '\n'; }
pow() { bluetoothctl show 2>/dev/null | awk '/^\tPowered/{print $2}'; }

dump_edge() {   # $1=old $2=new
    {
        echo ">>> 沿 $(date +%T): bt_power soft $1 → $2"
        echo "    同一瞬间：hci0 rfkill=$(rf hci0) hci0-flags=[$(hci)] bluez.Powered=$(pow)"
        echo "    桥计数（安卓侧日志尾，取整行）:"
        run "tail -n 400 /data/local/tmp/bt-bridge.log | grep -a 转发= | tail -3" | sed 's/^/      /'
        echo "    dmesg Δ:"
        run "dmesg 2>/dev/null | grep -i -e btpower -e bt_power -e bluetooth -e hci -e cnss -e glink -e ttyHS | tail -10" | sed 's/^/      /'
        echo "    logcat Δ（HAL/电源/rfkill 相关）:"
        run "logcat -d -t 800 2>/dev/null | grep -i -e ibs_handler -e SerialClockVote -e wake_lock -e btpower -e rfkill -e DataHandler -e PowerManager -e bluetooth@ | grep -v -e adbd -e ShellService | tail -25" | sed 's/^/      /'
        echo "    安卓侧状态:"
        run "getprop bluetooth.status; getprop persist.vendor.bluetooth.state; getprop init.svc.bluetooth; dumpsys power 2>/dev/null | grep -m1 -e mWakefulness=; dumpsys deviceidle 2>/dev/null | grep -m1 -e mState=" | sed 's/^/      /'
        echo "<<< 沿现场结束"
    } 2>&1 | tee -a "$OUT"
}

PREV=""
EDGES=0
echo "=== BT-POWER-WATCHER START $(date +%F_%T) 时长=${R}s 本地间隔=${IV}s 输出=$OUT ===" | tee -a "$OUT"
echo "时刻 | bt_power | hci0 rfkill | hci0 flags | bluez.Powered" | tee -a "$OUT"
end=$(( $(date +%s) + R ))
N=0
while [ "$(date +%s)" -lt "$end" ]; do
    S=$(rf bt_power)
    TS=$(date +%T)
    if [ -n "$PREV" ] && [ "$S" != "$PREV" ]; then
        EDGES=$((EDGES+1))
        dump_edge "$PREV" "$S"
    fi
    # 稳态每 30 拍（≈1 分钟）落一行摘要，日志不会被 2s 一拍撑爆
    if [ "$((N % 30))" = 0 ]; then
        printf "%s | bt_power=%s | hci0=%s | [%s] | Powered=%s\n" \
            "$TS" "$S" "$(rf hci0)" "$(hci)" "$(pow)" | tee -a "$OUT"
    fi
    PREV=$S
    N=$((N+1))
    sleep "$IV"
done
echo "=== BT-POWER-WATCHER DONE $(date +%T)：$N 拍，捕获沿 $EDGES 次（沿现场见上面 >>> 行 / $OUT）===" | tee -a "$OUT"
