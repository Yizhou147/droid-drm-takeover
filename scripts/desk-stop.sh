#!/bin/bash
# desk-stop.sh v2 — 结束 desk-takeover.sh 的全自动接管，把显示+WiFi 全部还给安卓。
# v1 教训(22:45 轮)：① pkill 模式与实际 cmdline 不符，kwin 没死→SF 抢不回 DRM master；
# ② 脚本没和终端脱钩，plasma 组件被杀时 konsole 一起没了→`start` 没执行→黑屏+断网。
# v2 对策：主体 setsid 脱离终端后台跑，前台只 tail 日志；杀桌面用"模式+验证重试+fuser兜底"；
# 拉起安卓后轮询 init.svc，不达标就补刀再 start。
ROOT="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
DIR=$ROOT
LOGD=${LOG_DIR:-$(dirname "$ROOT")/logs}
mkdir -p "$LOGD"
LOG=$LOGD/desk-stop.log

# ---- 自脱钩：第一段在 konsole 里，只负责把真身甩出去并转发日志 ----
if [ -z "$DESKSTOP_ID" ]; then
    DESKSTOP_ID="$$.start"
    export DESKSTOP_ID
    setsid nohup "$0" >>"$LOG" 2>&1 </dev/null &
    CHILD=$!
    tail -n +1 --pid=$CHILD -f "$LOG" 2>/dev/null
    exit 0
fi

trap '' HUP INT TERM
set +e
set -x
echo "=== DESK-STOP START $(date +%F_%T) id=$DESKSTOP_ID ==="

DEV=$(adb devices | awk '$2=="device"{print $1; exit}')
[ -n "$DEV" ] || { echo "NO-ADB-DEVICE"; exit 1; }
run() { adb -s "$DEV" shell "su -c '$1'"; }

# ---- 1) 杀 Linux 桌面栈：两套 kwin(接管 taketest / 系统 wayland-0)全模式覆盖 ----
kill_desktop() {
    pkill -9 -f "kwinwrap --out"
    pkill -9 -f "socket=taketest"
    pkill -9 -f "kwin_wayland_wrapper"
    pkill -9 -f "kwin_wayland --"
    pkill -9 -f "startplasma-wayland"
    pkill -9 -f "dbus-run-session"
    pkill -9 -f "plasmashell"
    pkill -9 -f "kactivitymanagerd"
    pkill -9 -f "plasma-keyboard"
    pkill -9 -f "xdg-desktop-portal"
    pkill -9 -f "dmesg-harvester.sh"
    pkill -9 -f 'wpa_supplicant.*desk-wifi'
    pkill -9 -f "nm-drm.conf"
    pkill -x NetworkManager
    pkill -9 -x dhcpcd
}
for i in 1 2 3; do
    kill_desktop
    sleep 1
    ALIVE=$(pgrep -f "kwin_wayland|kwinwrap|taketest" | grep -v "^$$\$")
    [ -z "$ALIVE" ] && break
    echo "round$i kwin still alive: $ALIVE -> kill -9 by pid"
    kill -9 $ALIVE 2>/dev/null
    sleep 1
done
# 兜底：谁还占着 card0 就杀谁（只剩 kwin 类会持有 master）
if [ -n "$ALIVE" ]; then
    fuser -k /dev/dri/card0 2>/dev/null
    sleep 2
fi

# ---- 2) 释放 wlan0 + 还原接管期动过的路由 + 拉起安卓全家 ----
pkill -x NetworkManager 2>/dev/null
ip -4 addr flush dev wlan0 2>/dev/null
if [ -f /run/desk-ip-rules.bak ]; then
    # desk-takeover 的 NM 段 flush 过 rule；原样还原，netd 回来会补建自己的规则
    ip rule flush; ip rule restore < /run/desk-ip-rules.bak && echo "ip-rule restored from bak"
fi
ip link set wlan0 down 2>/dev/null
run "echo qoderdbg > /sys/power/wake_unlock"
run "setprop ctl.start system_suspend; setprop ctl.start vendor.qti.hardware.display.composer; start"

# ---- 3) 轮询 surfaceflinger；没起来多半是 master 还被占 → 补刀再 start ----
SF=""
for i in $(seq 1 24); do
    SF=$(adb -s "$DEV" shell getprop init.svc.surfaceflinger 2>/dev/null | tr -d '\r')
    [ "$SF" = "running" ] && break
    if [ $((i % 6)) -eq 0 ]; then
        echo "poll$i SF=$SF -> kill_desktop again + start"
        kill_desktop
        run "setprop ctl.start system_suspend; start"
    fi
    sleep 5
done
echo "SURFACEFLINGER=$SF after poll"

# ---- 4) 亮屏解锁（system_server 死机期间的 PMS 状态需要键事件推一把）----
adb -s "$DEV" shell input keyevent 224 >/dev/null 2>&1
sleep 2
adb -s "$DEV" shell input keyevent 224 >/dev/null 2>&1
run "setprop ctl.stop bootanim; sleep 2; setprop ctl.stop bootanim"
adb -s "$DEV" shell "su -c 'wm dismiss-keyguard'" >/dev/null 2>&1
$DIR/bin/setbright 2048 >/dev/null 2>&1
rm -f $DIR/takeover.ok

# ---- 5) 结果取证 ----
sleep 10
run "getprop init.svc.surfaceflinger; getprop init.svc.zygote; getprop init.svc.wpa_supplicant"
run "dumpsys power | grep -m2 -E 'mWakefulness|mScreenOn'"
timeout 8 ping -c 2 -W 1 223.5.5.5 >/dev/null 2>&1 && echo "NET RESTORED VIA ANDROID" || echo "NET STILL DOWN after start"
echo "=== DESK-STOP DONE $(date +%T) ==="
