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

DEV=$(timeout 12 adb devices | awk '$2=="device"{print $1; exit}')
[ -n "$DEV" ] || { echo "NO-ADB-DEVICE"; exit 1; }
run() {
    # timeout 只是保命；124 必须打进日志，否则下次又只剩"某行之后没输出"这种糊账
    local out rc
    out=$(timeout 12 adb -s "$DEV" shell "su -c '$1'" 2>&1); rc=$?
    [ $rc -eq 124 ] && echo "RUN-TIMEOUT(12s): $1"
    printf '%s\n' "$out"
    return $rc
}

# ---- 0) 保命看门狗：主流程任意一步卡死/被杀，50s 后无条件把安卓拉起来 ----
# 09-24 16:52 轮实锤：desk-stop 卡死在它第一个 adb 调用上（run 原本没有 timeout，adb
# server 抽风就永久阻塞），日志到 wake_unlock 那行就断，`start` 从未执行 → 桌面已被杀完
# + 框架没起 = 纯黑屏，只能长按电源强启（和 v1 "脚本没脱钩→start 没执行" 同一类后果）。
# 主流程 start 前 touch /run/deskstop-started，看门狗见标即退 → 正常轮次零影响。
STARTED_FLAG=/run/deskstop-started
rm -f $STARTED_FLAG
(
    sleep 50
    [ -f $STARTED_FLAG ] && exit 0
    echo "=== WATCHDOG FIRED $(date +%T)：主流程没走到 start，强制交还安卓 ==="
    pkill -9 -f "kwinwrap --out"; pkill -9 -f "socket=taketest"
    pkill -9 -f "kwin_wayland --"; pkill -9 -f "plasmashell"
    pkill -9 -x bthci-bridge   # 放掉容器侧 HCI 接管（进程退→tty 关→内核自动注销 hci0）
    WDEV=$(timeout 12 adb devices | awk '$2=="device"{print $1; exit}')
    if [ -z "$WDEV" ]; then
        echo "WATCHDOG: adb 通道也没了，只能硬重启（这一步救不了）"
    else
        timeout 12 adb -s "$WDEV" shell "su -c 'echo qoderdbg > /sys/power/wake_unlock'"
        timeout 15 adb -s "$WDEV" shell "su -c 'setprop ctl.start vendor.qti.hardware.display.composer; setprop ctl.start system_suspend; start'"
        sleep 15
        timeout 12 adb -s "$WDEV" shell "su -c 'setprop ctl.stop bootanim; sleep 2; setprop ctl.stop bootanim'"
        timeout 12 adb -s "$WDEV" shell "input keyevent 224"
        echo "=== WATCHDOG DONE: SF=$(timeout 12 adb -s "$WDEV" shell getprop init.svc.surfaceflinger | tr -d '\r') ==="
    fi
    sync
) >> "$LOG" 2>&1 &
WATCHDOG_PID=$!
echo "WATCHDOG_PID=$WATCHDOG_PID (50s 后若无 start 标即自救)"

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
    pkill -9 -f "org_kde_powerdevil"
    pkill -9 -f "plasma-keyboard"
    pkill -x fcitx5
    pkill -x onboard
    pkill -9 -f "xdg-desktop-portal"
    pkill -9 -f "dmesg-harvester.sh"
    # Xwayland 由 kwin --xwayland 拉起（09-24 接入），是 kwin 的子进程；kwin 被 -9 时
    # 它未必跟着退，残留会占住 display 号与 /tmp/.X11-unix/X<n> 死套接字
    pkill -9 -x Xwayland
    # 容器与安卓共享 netns → wlan0 只能有一个主人。09-24 起 supplicant 是自拉 nohup 版
    # （cmdline `wpa_supplicant -u -t -O ...`，不含 desk-wifi），旧模式永远杀不到它，
    # 残留进程攥着 nl80211/D-Bus 控制权 → 回安卓后 WiFi 开关点了没反应，只能重启（09-24 两次实测）。
    [ -f /run/desk-wpa.pid ] && kill -9 "$(cat /run/desk-wpa.pid)" 2>/dev/null
    rm -f /run/desk-wpa.pid
    pkill -9 -f 'wpa_supplicant -u'        # 容器自拉版 + NM D-Bus 激活版都算（安卓版是 -O/data/vendor/... 无 -u，杀不到）
    pkill -9 -f 'wpa_supplicant.*desk-wifi'   # 静态 conf fallback 版
    pkill -9 -f 'strace.*-strace.txt'      # 接管期的 wpa/NM strace 尾巴
    pkill -9 -f "nm-drm.conf"
    pkill -x NetworkManager
    # udevd 活着就会在安卓重建 wlan0 的 uevent 上二次改名（wlp1s0，09-24 事故主角）；
    # 接管期它只是 NM 的工具，交还后必须闭嘴。下一轮 desk-takeover 会重新拉起。
    pkill -9 -x systemd-udevd
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
# 蓝牙接管桥必须先死：它活着 = 容器占着 pty/hci0，安卓重启后自己的 BT 栈抢不到通道。
# 桥退出即关 tty → 内核自动注销 hci0，安卓侧无需任何还原（安卓开机本来就会自开 BT）。
pkill -x bthci-bridge 2>/dev/null
pkill -x NetworkManager 2>/dev/null
# NM 经 D-Bus 激活的 wpa_supplicant 会赖在总线上；只停容器 systemd 的实例（安卓那侧不受影响）
systemctl stop wpa_supplicant.service 2>/dev/null
ip -4 addr flush dev wlan0 2>/dev/null
if [ -f /run/desk-ip-rules.bak ]; then
    # desk-takeover 的 NM 段 flush 过 rule；原样还原，netd 回来会补建自己的规则
    ip rule flush; ip rule restore < /run/desk-ip-rules.bak && echo "ip-rule restored from bak"
fi
ip link set wlan0 down 2>/dev/null
# 交还前的残留检查（必须在 4b 重启 anland 会话之前取，否则会把 anland 自己正常拉起的
# NM/supplicant 误报成泄漏）：容器里还有 wpa_supplicant 活着 = wlan0 主人没换干净
LEFT=$(pgrep -f 'wpa_supplicant' | tr '\n' ' ')
[ -n "$LEFT" ] && echo "WIFI-HANDOVER LEAK: 容器侧仍有 $(pgrep -fa wpa_supplicant | tr '\n' ';')"
# 改名自愈：wlan0 若已被容器 udevd 改成 wlpXXX，安卓找不到自己的网卡 → WiFi 永久废掉。
# 趁安卓 framework 还没 start、网卡无人使用时改回来（09-24 现场实测：这一步就能免掉重启）。
MIS=$(ip -o link 2>/dev/null | grep -oE "wlp[a-z0-9]+" | head -1)
if [ -n "$MIS" ] && ! ip -o link show wlan0 >/dev/null 2>&1; then
    ip link set "$MIS" down 2>/dev/null
    if ip link set "$MIS" name wlan0 2>/dev/null; then
        echo "WIFI-RENAME-FIX: $MIS -> wlan0 OK"
    else
        echo "WIFI-RENAME-FIX: $MIS -> wlan0 FAILED（接口被占/EBUSY，安卓 WiFi 大概率要重启才恢复）"
    fi
fi
run "echo qoderdbg > /sys/power/wake_unlock"
# 交还安卓=本脚本的命根子：单发 adb 调用一旦卡住，start 永不执行就是黑屏（09-24 16:52 轮）。
# 所以重试到亲眼确认 zygote running 为止；确认前不打 STARTED 标，让看门狗仍然可自救。
for t in 1 2 3 4 5; do
    run "setprop ctl.start system_suspend; setprop ctl.start vendor.qti.hardware.display.composer; start"
    sleep 8
    Z=$(run "getprop init.svc.zygote" 2>/dev/null | tr -d '\r')
    echo "START try$t zygote=$Z"
    if [ "$Z" = "running" ]; then touch $STARTED_FLAG; sync; break; fi
    sleep 3
done

# ---- 3) 轮询 surfaceflinger；没起来多半是 master 还被占 → 补刀再 start ----
SF=""
for i in $(seq 1 24); do
    SF=$(timeout 12 adb -s "$DEV" shell getprop init.svc.surfaceflinger 2>/dev/null | tr -d '\r')
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
timeout 12 adb -s "$DEV" shell input keyevent 224 >/dev/null 2>&1
sleep 2
timeout 12 adb -s "$DEV" shell input keyevent 224 >/dev/null 2>&1
run "setprop ctl.stop bootanim; sleep 2; setprop ctl.stop bootanim"
timeout 12 adb -s "$DEV" shell "su -c 'wm dismiss-keyguard'" >/dev/null 2>&1
$DIR/bin/setbright 2048 >/dev/null 2>&1
rm -f $DIR/takeover.ok

# ---- 4b) 复活 anland Linux 会话（kill_desktop 把它的 kwin/plasma 也顺带杀了，
#          不补起来 Droid Spaces 打开就是白屏，只能重启容器——09-23 用户实测痛点） ----
if [ -x /usr/local/bin/startanland-kde.sh ] || [ -f /usr/local/bin/startanland-kde.sh ]; then
    runuser -u xieyizhou -- bash -c 'nohup /usr/local/bin/startanland-kde.sh > /tmp/anland-restart.log 2>&1 &' \
        && echo "anland session relaunched"
fi

# ---- 4b2) 蓝牙交还确认：桥必须已经死干净（它活着=容器还占着 hci0 的 tty，
#          安卓自己的蓝牙栈起不来；实测安卓开机/重启服务时会自己重新 enable）----
BTLEFT=$(pgrep -x bthci-bridge | tr '\n' ' ')
if [ -n "$BTLEFT" ]; then
    pkill -9 -x bthci-bridge; sleep 1
    echo "BT-LEAK: 桥没死干净($BTLEFT) → 已强杀（hci0 随 tty 关闭自动注销）"
else
    echo "BT-HANDOVER OK $(date +%T): 容器侧无残留桥"
fi
[ -e /sys/class/bluetooth/hci0 ] && echo "BT-WARN: /sys/class/bluetooth/hci0 还在（注销慢一拍或另有持有者）"

# ---- 4c) WiFi 交还取证（容器与安卓共享 netns，wlan0 只能有一个主人；
#          安卓侧要等 wifi 状态机自己跑完才有结论，故 sleep 后再抓） ----
WF=$LOGD/wifi-forensic-$(date +%m%d-%H%M%S).log
sleep 20
{
    echo "### $(date)  left_container_supplicant=[$LEFT]"
    echo "=== settings"; run "settings get global wifi_on"
    echo "=== dumpsys wifi head"; run "dumpsys wifi 2>/dev/null | head -30"
    echo "=== iw dev wlan0 link"; run "iw dev wlan0 link 2>/dev/null | head -6"
    # 注意：run() 会把参数塞进单引号里给 su -c，所以这里内层只能用双引号
    echo "=== logcat wifi"; run "logcat -d 2>/dev/null | grep -iE \"wifiservice|activemode|wifinative|wificond|HalDevMgmt|StaIface\" | tail -30"
} > "$WF" 2>&1
echo "WIFI-FORENSIC -> $WF"
# 没连上就用安卓官方路径推一次状态机（等价于设置里关开一次），结果追加进同一份取证
if ! run "iw dev wlan0 link 2>/dev/null | head -1" 2>/dev/null | grep -q "Connected to"; then
    echo "WIFI-NUDGE: wlan0 未关联 → svc wifi disable/enable"
    run "svc wifi disable"; sleep 3
    run "svc wifi enable"; sleep 12
    run "iw dev wlan0 link 2>/dev/null | head -4; settings get global wifi_on" >> "$WF" 2>&1
fi

# ---- 5) 结果取证 ----
sleep 10
run "getprop init.svc.surfaceflinger; getprop init.svc.zygote; getprop init.svc.wpa_supplicant"
run "dumpsys power 2>/dev/null | grep -m1 -E \"mWakefulness=\" ; dumpsys display 2>/dev/null | grep -m1 -E \"mScreenState=\""
timeout 8 ping -c 2 -W 1 223.5.5.5 >/dev/null 2>&1 && echo "NET RESTORED VIA ANDROID" || echo "NET STILL DOWN after start"
echo "=== DESK-STOP DONE $(date +%T) ==="
