#!/bin/bash
# bt-power-watcher.sh — 只读取证：谁在收蓝牙芯片的电源。跑法：bash bt-power-watcher.sh [秒=180]
#
# 采样对齐到同一时间轴的四路独立信号：
#   A. 内核 rfkill：`bt_power`（vendor 电源域）与 `hci0`（每设备）各自的 soft/hard
#   B. 内核侧适配器真实状态：`hciconfig hci0` 的 flags + TX commands/errors
#   C. 安卓侧：`persist.vendor.bluetooth.state`、framework BT 服务与 app 进程是否活着
#   D. 桥自己的计数（转发=内核→HAL 命令方向）
# 一旦 A 的 bt_power soft **发生翻转**（0↔1），立刻打一条沿触发行并把那一刻的 logcat 尾部
# 整段抓下来 —— 只有沿上才有"是谁做的"证据，定期采样是抓不到的。
#
# 三条探针纪律（都是 09-30 实测踩出来的，别再犯）：
#   · 查进程用 `ps -A -o PID,NAME` 比对**进程名**，绝不用 `pgrep -f <包含点的字符串>`：
#     那条字符串会出现在我自己 adb 命令的 cmdline 里 → 每轮 pid 都在变 = 纯假象；
#   · 大文件计数用 `tail -n N` 按行取，`tail -c` 会切半行导致"读不到"被当成"冻住"；
#   · `/sys/class/bluetooth/hci0/{address,flags}` 本机不存在（root 也读不到），不能当健康判据。
# 全程零写入、不碰 rfkill、不动桥、不重启任何服务。
DEV=$(adb devices | awk '$2=="device"{print $1; exit}')
[ -n "$DEV" ] || { echo "NO-ADB"; exit 1; }
R=${1:-180}
BTLOG=/data/local/tmp/bt-bridge.log
PREV_SOFT=""
PREV_LC=""
run() { timeout 10 adb -s "$DEV" shell "su -c '$1'" 2>&1 | tr -d '\r'; }
read_soft() {
    for f in /sys/class/rfkill/rfkill*; do
        [ "$(cat $f/name 2>/dev/null)" = "$1" ] && { cat $f/soft 2>/dev/null; return; }
    done
    echo NOREAD
}

echo "=== BT-POWER-WATCHER START $(date +%F_%T) 时长=${R}s ==="
echo "时刻 | bt_power soft/hard | hci0 soft/hard | hciconfig flags | TX cmd/err | persist.state | svc.bluetooth | BT进程数 | 桥计数"
end=$(( $(date +%s) + R ))
while [ "$(date +%s)" -lt "$end" ]; do
    TS=$(date +%T)
    S1=$(read_soft bt_power); H1=$(cat /sys/class/rfkill/rfkill*/hard 2>/dev/null | head -1)
    S2=$(read_soft hci0)
    HCI=$(hciconfig hci0 2>/dev/null | awk 'NR==3' | sed 's/^ *//')
    TXE=$(hciconfig -a hci0 2>/dev/null | grep -o "TX bytes.*" | head -1)
    # 注意：run() 会把整条命令塞进 su -c '...'，所以**内部不能再出现单引号**
    # （上一版里的 awk '...' 和 grep -a '...' 都被打断，报错行还会把后面的列挤位）
    A=$(run "getprop persist.vendor.bluetooth.state; getprop init.svc.bluetooth; ps -A -o NAME= | grep -cx com.android.bluetooth; tail -n 400 $BTLOG | grep -a 转发= | tail -1")
    PS=$(echo "$A" | sed -n 1p); SVC=$(echo "$A" | sed -n 2p); NPI=$(echo "$A" | sed -n 3p)
    CNT=$(echo "$A" | sed -n 4p | sed -n 's/.*转发=\([0-9]*\) 收回=\([0-9]*\) 回调=\([0-9]*\).*/\1 \2 \3/p')
    echo "$TS | bt_power=$S1 | hci0=$S2 | [$HCI] | ${TXE:-无} | persist=${PS:-NOREAD} | svc=${SVC:-空} | btdApp=${NPI:-NOREAD} | ${CNT:-NOREAD}"

    if [ -n "$PREV_SOFT" ] && [ "$S1" != "$PREV_SOFT" ]; then
        echo ">>> 沿触发 $(date +%T): bt_power soft $PREV_SOFT → $S1 —— 抓这一秒的现场 <<<"
        echo "    hciconfig: $(hciconfig -a hci0 2>&1 | head -4 | tr '\n' ' ')"
        echo "    dmesg Δ:"; run "dmesg 2>/dev/null | grep -iE btpower -e bt_power -e bluetooth -e hci -e cnss -e glink | tail -8" | sed 's/^/      /'
        echo "    logcat Δ:"; run "logcat -d -t 300 2>/dev/null | grep -iE bluetooth -e btpower -e rfkill -e ibs_ -e DataHandler -e PowerManager -e suspend | grep -viE adbd -e ShellService | tail -18" | sed 's/^/      /'
    fi
    PREV_SOFT=$S1
    sleep 5
done
echo "=== BT-POWER-WATCHER DONE $(date +%T) 期间沿次数见上面 >>> 行 ==="
