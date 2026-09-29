#!/bin/bash
# bt-keepalive.sh — 接管轮内的蓝牙守门人：保证"默认开 + 关不掉"，并在桥卡死时自愈。
# 定位与 WiFi 侧的 polkit NO 规则相同（见 desk-takeover.sh 60-nm-drm.rules），但蓝牙这里
# 多一层：bluetoothd 不接 polkit，策略只能挡普通用户（61-bluez-drm-lock.conf），
# root/bluetoothctl/rfkill 这类路径必须由本进程兜住 —— 所以"策略硬拒 + 看门狗回开"是双保险。
#
# 三件事，按优先级：
#   ① 熔断（红线，见工作总结 §蓝牙桥运行窗口）：init.svc.surfaceflinger=running 说明已交还
#      安卓，安卓自己的蓝牙栈会重新持有 HAL —— 本进程必须立刻退出，绝不与之并存。
#   ② 保活：Powered 不是 yes → 立刻 power on；连续要不来就判桥卡死。
#   ③ 自愈：桥进程在、但内核侧 hci0 只剩空壳（address 读不到）或 power on 连轮拿不到
#      Powered: yes → pkill -x bthci-bridge 重拉（09-29 实证的"单向死"：HAL→内核的事件洪水
#      还在涨，内核→HAL 的命令计数冻结，HCI_Reset 无人应答，power on 只报 Failed 且不自愈）。
#
# 只做蓝牙侧动作：不碰 rfkill ioctl、不碰 ttyHS0/btpower、不重启任何服务。
DEV=$(adb devices | awk '$2=="device"{print $1; exit}')
[ -n "$DEV" ] || { echo "BT-KEEPALIVE EXIT $(date +%T): 没有 adb 设备，无法观测安卓侧状态"; exit 0; }
run() {
    local out rc
    out=$(timeout 8 adb -s "$DEV" shell "su -c '$1'" 2>&1); rc=$?
    [ $rc -eq 124 ] && echo "BT-KEEPALIVE RUN-TIMEOUT(8s): $1"
    printf '%s\n' "$out"
}
BTBIN=${BTBIN:-/data/local/tmp/bthci-bridge}
BTLOG=${BTLOG:-/data/local/tmp/bt-bridge.log}
INTERVAL=${INTERVAL:-10}
POWFAIL_MAX=2          # 连续几轮 power on 要不来 Powered:yes 就重拉桥
RESTART_COOLDOWN=30    # 重拉后静默：HAL 被反复 initialize 会回 INITIALIZATION_ERROR（日志实证）
NEXT_OK=0
FAILS=0
RECOVERS=0

ctl() { bluetoothctl "$@" 2>/dev/null; }
powered() { ctl show | grep -q 'Powered: yes'; }

restart_bridge() {
    # pkill -f 会连 su -c 那层 shell 一起杀（表现为 rc=143 的假失败）⇒ 一律 -x
    run "pkill -x bthci-bridge"
    sleep 2
    run "pgrep -x bthci-bridge || nohup $BTBIN --keep 0 >>$BTLOG 2>&1 &"
    RESTART_COOLDOWN_MARK=$(( $(date +%s) + RESTART_COOLDOWN ))
    RECOVERS=$(( RECOVERS + 1 ))
    echo "BT-RECOVER #$RECOVERS $(date +%T): 已重拉桥（判据=power on 连轮无 Powered:yes / hci0 空壳）"
}

echo "=== BT-KEEPALIVE START $(date +%F_%T) interval=${INTERVAL}s ==="
while :; do
    SF=$(run "getprop init.svc.surfaceflinger" | tr -d '\r' | tail -1)
    if [ "$SF" = "running" ]; then
        echo "BT-KEEPALIVE FUSE $(date +%T): surfaceflinger=running（已交还安卓），自退并把 HAL 客户端位还给安卓"
        exit 0
    fi
    if ! run "test -x $BTBIN && echo YES" | grep -q YES; then
        echo "BT-KEEPALIVE EXIT $(date +%T): $BTBIN 不在，无事可做"
        exit 0
    fi

    if powered; then
        [ "$FAILS" != 0 ] && echo "BT-KEEPALIVE RECOVERED $(date +%T): Powered: yes（此前连轮 $FAILS）"
        FAILS=0
        sleep "$INTERVAL"
        continue
    fi

    # 没在电源态上 → 先要一次；顺带取回判定用的原始证据（判据不能只报"否"，
    # 否则"没测到"会伪装成"没有"，见工作总结 §探针自证纪律）
    ctl power on >/dev/null
    NOW=$(date +%s)
    if [ "$NOW" -lt "$NEXT_OK" ]; then
        echo "BT-KEEPALIVE COOLDOWN $(date +%T): 距上次重拉 $(( NEXT_OK - NOW ))s，暂不再动桥"
        sleep "$INTERVAL"; continue
    fi
    sleep 3
    SHOW=$(ctl show)
    HP=$(cat /sys/class/bluetooth/hci0/address 2>&1)
    BRIDGE=$(run "pgrep -x bthci-bridge" | tr -d '\r' | head -1)
    # 顺带把 bt 的 rfkill 现场钉在证据行里：09-29 那次"打不开"最后没能归因清楚（bluez 日志里
    # 有一次 adapter power down，而非 root 的属性写本来就被总线拒，说明下电不是用户点出来的，
    # 但没采到 rfkill 侧同时刻的 soft/hard，断不了链）。本进程**只读不写** rfkill——
    # 芯片上下电的正经入口归 vendor HAL，手动碰它踩过红线（见 工作总结 §蓝牙红线）。
    RF=$(for r in /sys/class/rfkill/rfkill*; do
             [ "$(cat $r/type 2>/dev/null)" = bluetooth ] || continue
             echo -n "$(basename $r):soft=$(cat $r/soft 2>/dev/null),hard=$(cat $r/hard 2>/dev/null) "
         done)
    echo "BT-KEEPALIVE NOT-POWERED $(date +%T): $(echo "$SHOW" | grep -E 'Powered|PowerState' | tr '\n' ' ') hci0.address=[$HP] rfkill=[${RF:-none}] bridge=[${BRIDGE:-DEAD}]"

    if [ -z "$BRIDGE" ]; then
        echo "BT-KEEPALIVE RESTART $(date +%T): 桥没在跑 → 直接拉起"
        restart_bridge; FAILS=0; NEXT_OK=$RESTART_COOLDOWN_MARK
        continue
    fi
    FAILS=$(( FAILS + 1 ))
    if [ "$FAILS" -ge "$POWFAIL_MAX" ] || ! echo "$SHOW" | grep -q '^Controller'; then
        restart_bridge; FAILS=0; NEXT_OK=$RESTART_COOLDOWN_MARK
    fi
    sleep "$INTERVAL"
done
