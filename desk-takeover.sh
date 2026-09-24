#!/bin/bash
# desk-takeover.sh — 全自动无网接力：stop 安卓 → kwin DRM 持屏 + Plasma 桌面 → 容器接管 WiFi。
# 顺序按用户要求：先桌面，再网络。全程不需要我在线（adb 走本机 emulator-5554 通道）。
# 任一关键步失败 → 自动回滚（恢复安卓全家，含 system_suspend 显式拉起，防 Scout 重启）。
ROOT="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
DIR=$ROOT
LOGD=${LOG_DIR:-$(dirname "$ROOT")/logs}
mkdir -p "$LOGD"

# ---- 自脱钩（09-23 黑屏事故教训，同 desk-stop v2）：快捷方式从桌面 konsole 进来时，
#      konsole 是将被本脚本杀掉的 kwin 的客户端；kwin 一死 pty 关闭，前台脚本陪葬，
#      而此时安卓已 stop → 两头全黑。主体必须 setsid 脱离终端。 ----
if [ -z "$DESKSTART_ID" ]; then
    DESKSTART_ID="$$.start"
    export DESKSTART_ID
    setsid nohup "$0" >>"$LOGD/desk-takeover.log" 2>&1 </dev/null &
    CHILD=$!
    tail -n 60 --pid=$CHILD -f "$LOGD/desk-takeover.log" 2>/dev/null
    exit 0
fi
trap '' HUP INT TERM

exec >>"$LOGD/desk-takeover.log" 2>&1
set -x
echo "=== DESK-TAKEOVER START $(date +%F_%T) ==="

WIFI_CONF=/root/desk-wifi.conf
# 仅兜底；正常路径 dhcpcd 拿租约后动态探测 GW/网段（换网不用改这里）
IP=172.16.30.104
PREFIX=22
GW=172.16.30.1

DEV=$(adb devices | awk '$2=="device"{print $1; exit}')
[ -n "$DEV" ] || { echo "NO-ADB-DEVICE"; exit 1; }
run() { adb -s "$DEV" shell "su -c '$1'"; }
kill_linux_stack() {
    # v2: 补全实际 cmdline 模式(v1 的 kwinwrap/socket 模式杀不掉真 kwin)，见 desk-stop.sh 头注
    pkill -9 -f "kwinwrap --out" 2>/dev/null
    pkill -9 -f "socket=taketest" 2>/dev/null
    pkill -9 -f "kwin_wayland_wrapper" 2>/dev/null
    pkill -9 -f "kwin_wayland --" 2>/dev/null
    pkill -9 -f "startplasma-wayland" 2>/dev/null
    pkill -9 -f "plasmashell" 2>/dev/null
    pkill -9 -f "kactivitymanagerd" 2>/dev/null
    pkill -9 -f "org_kde_powerdevil" 2>/dev/null
    pkill -9 -f "plasma-keyboard" 2>/dev/null
    pkill -x fcitx5 2>/dev/null
    pkill -x onboard 2>/dev/null
    pkill -9 -f "dmesg-harvester.sh" 2>/dev/null
    pkill -f 'wpa_supplicant.*desk-wifi' 2>/dev/null
    pkill -f "nm-drm.conf" 2>/dev/null
    pkill -x NetworkManager 2>/dev/null
    systemctl stop wpa_supplicant.service 2>/dev/null   # 清掉上一轮 NM 遗留的 supplicant（仅容器实例）
    pkill -x dhcpcd 2>/dev/null
    pkill -f "xdg-desktop-portal" 2>/dev/null
    sleep 1
    fuser -k /dev/dri/card0 2>/dev/null
    rm -f $DIR/takeover.ok
}
rollback() {
    echo "ROLLBACK: $* ($(date +%T))"
    kill_linux_stack
    # system_suspend 被 ctl.stop 后 `start` 拉不起它，新 system_server 会在
    # PowerManagerService.<init> waitForService(android.system.suspend) 卡死
    # → MIUIScout FW_SCOUT_HANG → 自动重启。必须先显式 ctl.start。
    run "echo qoderdbg > /sys/power/wake_unlock; setprop ctl.start system_suspend; setprop ctl.start vendor.qti.hardware.display.composer; start"
    sleep 6
    run "setprop ctl.stop bootanim; sleep 2; setprop ctl.stop bootanim"
    $DIR/bin/setbright 2048 >/dev/null 2>&1
    adb -s "$DEV" shell input keyevent 224 >/dev/null 2>&1
    exit 1
}

# ---- 0) 预检+自动生成网络配置：从安卓现读当前连接的 SSID/PSK（换网零改动），
#         /root/desk-wifi.conf 仅作兜底；都没有也放行——网络尽力而为，桌面优先 ----
WIFI_GEN=/run/desk-wifi-dyn.conf
CUR_SSID=$(adb -s "$DEV" shell "cmd wifi status" 2>/dev/null | sed -n 's/.*connected to "\(.*\)".*/\1/p' | tr -d '\r')
CUR_PSK=$(adb -s "$DEV" shell "su -c 'grep -A2 \"&quot;$CUR_SSID&quot;<\" /data/misc/apexdata/com.android.wifi/WifiConfigStore.xml'" 2>/dev/null | sed -n 's/.*<string name="PreSharedKey">&quot;\(.*\)&quot;<.*/\1/p' | tr -d '\r' | head -1)
if [ -n "$CUR_SSID" ] && [ -n "$CUR_PSK" ]; then
    printf 'ctrl_interface=/run/wpa-takeover\nupdate_config=0\nap_scan=1\npmf=1\nsae_pwe=2\n' > "$WIFI_GEN"
    printf '%s' "$CUR_PSK" | wpa_passphrase "$CUR_SSID" >> "$WIFI_GEN"
    WIFI_CONF=$WIFI_GEN
    echo "WIFI-GEN OK for SSID[$CUR_SSID]"
else
    rm -f "$WIFI_GEN"   # 防上一轮遗留的过期配置被误用
    [ -f "$WIFI_CONF" ] && echo "WIFI-GEN miss(ssid=[$CUR_SSID]), fallback to static conf" \
        || echo "WIFI-GEN miss and no static conf: desktop will run WITHOUT network"
fi

# ---- 1) DRM 节点 + udev 合成记录（与 drm-takeover.sh 同源） ----
mkdir -p /dev/dri /dev/input
[ -c /dev/dri/card0 ] || mknod /dev/dri/card0 c 226 0
# NM 靠 rfkill netlink 控制 WiFi 射频；容器重启后 /dev 重建，缺这节点=扫不到任何热点（09-23 实锤）
[ -c /dev/rfkill ] || mknod /dev/rfkill c 10 242
chmod 666 /dev/rfkill 2>/dev/null
# pc-keyd（PC 布局组合键守护）的 uinput 注入要这个节点（内核 CONFIG_INPUT_UINPUT=y，只差节点）
[ -c /dev/uinput ] || mknod /dev/uinput c 10 223
chmod 666 /dev/uinput 2>/dev/null
# pc-keyd（组合键守护）必须在 kwin 之前在场。只从本脚本 nohup 起（防开机
# crash-loop 触发内核 uinput 防滥用；daemon 源码已独立成仓 droid-pc-keyboard，
# 装在 /usr/local/bin/pc-keyd.py。详见 https://github.com/Yizhou147/droid-pc-keyboard）。
pgrep -f "pc-keyd.py" >/dev/null || nohup python3 /usr/local/bin/pc-keyd.py > /tmp/pc-keyd.log 2>&1 &
# power-state-sync：小米 BSP 电流符号与内核 ABI 相反 → upower 永远判放电。
# bind-mount 取反 current_now + 周期 kick（脚本自带幂等挂载判断；跨会话常驻，
# desk-stop 不杀它，anland 托盘顺带受益）。
[ -f /usr/local/bin/power-state-sync.py ] && { pgrep -f "power-state-sync" >/dev/null || nohup python3 /usr/local/bin/power-state-sync.py > /tmp/power-sync.log 2>&1 & }
chmod 666 /dev/dri/card0 2>/dev/null
[ -c /dev/input/event11 ] || mknod /dev/input/event11 c 13 75
chmod 666 /dev/input/event11 2>/dev/null
if [ ! -f /run/udev/data/c226:0 ] || ! grep -q DRIVER /run/udev/data/c226:0; then
    mkdir -p /run/udev/data
    printf 'Q:100\nE:DEVPATH=/devices/platform/soc/ae00000.qcom,mdss_mdp/drm/card0\nE:MAJOR=226\nE:MINOR=0\nE:SUBSYSTEM=drm\nE:DEVTYPE=drm_minor\nE:DEVNAME=dri/card0\nE:DRIVER=vmwgfx\nH:uaccess\nH:seat\n' > /run/udev/data/c226:0
    printf 'Q:101\nE:DEVPATH=/devices/platform/soc/ae00000.qcom,mdss_mdp/drm/renderD128\nE:MAJOR=226\nE:MINOR=128\nE:SUBSYSTEM=drm\nE:DEVTYPE=drm_minor\nE:DEVNAME=dri/renderD128\nE:DRIVER=vmwgfx\nH:uaccess\nH:seat\n' > /run/udev/data/c226:128
    printf 'Q:100\nE:DEVPATH=/devices/virtual/input/input11\nE:MAJOR=13\nE:MINOR=75\nE:SUBSYSTEM=input\nE:DEVNAME=input/event11\nE:ID_INPUT=1\nE:ID_INPUT_TOUCH=1\nE:ID_INPUT_TOUCHSCREEN=1\nE:LIBINPUT_DEVICE_GROUP=11/6/15d9:NVTCapacitiveTouchScreen\nE:LIBINPUT_CALIBRATION_MATRIX=0 1 0 -1 0 1 0 0 1\nH:uaccess\nH:seat\n' > /run/udev/data/c13:75
    chmod -R a+rX /run/udev
fi

# ---- 2) 悬停保护 + 放倒安卓框架（网会掉 ~10-40s，属预期） ----
run "setprop ctl.stop system_suspend"
run "echo qoderdbg > /sys/power/wake_lock"
run "stop"
# stop 不动 class hal！composer HAL 活着就还持有 DRM master（SET_MASTER EBUSY），
# kwin 拿不到屏 → 黑屏（09-21 的坑，drm-takeover 同款处理）
run "setprop ctl.stop vendor.qti.hardware.display.composer"
sleep 5

# ---- IM：plasma-keyboard 本体路线（09-23 定案）----
# Qt 应用必须走 kwin 合成器 text-input 才会触发 kwin 自拉 plasma-keyboard，
# 所以本会话剥离 QT_IM_MODULE（/etc/environment 保持干净是给 anland 用的）；
# 中文=官方 Qt VirtualKeyboard Pinyin 插件（droid-pc-keyboard 仓库 scripts/install-pinyin-plugin.sh 一次性装入），
# 布局列表写 plasmakeyboardrc.enabledLocales。
sed -i 's/^\(enabledLocales=\).*/\1en_US,zh_CN/' /home/xieyizhou/.config/plasmakeyboardrc 2>/dev/null \
    || printf '[General]\nenabledLocales=en_US,zh_CN\n' > /home/xieyizhou/.config/plasmakeyboardrc
chown xieyizhou:xieyizhou /home/xieyizhou/.config/plasmakeyboardrc 2>/dev/null
grep -q "^VirtualKeyboardEnabled=true" /home/xieyizhou/.config/kwinrc 2>/dev/null \
    && : || sed -i 's/^VirtualKeyboardEnabled=.*/VirtualKeyboardEnabled=true/' /home/xieyizhou/.config/kwinrc

# ---- 3) kwin 接管显示（SF 已随 stop 死亡，master 天然空闲）→ 先出桌面 ----
kill_linux_stack
rm -f $DIR/takeover.ok
env KWINWRAP_HIJACK=1 KWINWRAP_FILTER=1 KWINWRAP_SECCOMP=1 \
    KWINWRAP_UID=1000 KWINWRAP_GID=1000 KWINWRAP_BRIGHTNESS=2048 \
    $DIR/bin/kwinwrap --out $LOGD/kwinatomic.log -- \
    env -u DISPLAY -u WAYLAND_DISPLAY HOME=/home/xieyizhou \
        KWIN_DRM_DEVICES=/dev/dri/card0 \
        FD_MESA_DEBUG=noubwc \
        KWIN_WAYLAND_NO_PERMISSION_CHECKS=1 \
        XDG_SESSION_ID=bogus \
        XDG_RUNTIME_DIR=/run/user/1000 \
        DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus \
        kwin_wayland --socket=taketest \
    > $LOGD/kwin.log 2>&1 &
KPID=$!
sleep 6
kill -0 $KPID 2>/dev/null || rollback "kwin died (see kwin.log)"
runuser -u xieyizhou -- env -u DISPLAY WAYLAND_DISPLAY=taketest \
    HOME=/home/xieyizhou XDG_RUNTIME_DIR=/run/user/1000 \
    QT_QPA_PLATFORM=wayland \
    timeout 5 wayland-info > $LOGD/wayland-info.log 2>&1
[ $? = 0 ] || rollback "wayland-info self-check failed"
# ---- 3b) 上屏取证 + 强制点亮：stop 时 system_server 死前会走关机流程把屏灭掉，
#      kwin 新 commit 不一定把 connector DPMS 拉回 On → 黑屏。主动写 dpms=0。 ----
$DIR/bin/crtcstate > $LOGD/crtcstate-desk.log 2>&1
$DIR/bin/connprops > $LOGD/connprops-desk.log 2>&1
$DIR/bin/setprop 0 DPMS
$DIR/bin/setbright 2048 > /dev/null 2>&1
sleep 2
$DIR/bin/crtcstate > $LOGD/crtcstate-desk2.log 2>&1

# ---- 4) Plasma 桌面 ----
# 09-23 黑屏根因：plasmashell 硬依赖 kactivitymanagerd，总线自动激活今天直接超时
# （"Aborting shell load: The activity manager daemon is not running" → 无壳黑屏）。
# 不再赌 dbus 激活：显式拉起并等名字出现。
nohup runuser -u xieyizhou -- env -u DISPLAY -u QT_IM_MODULE -u GTK_IM_MODULE -u XMODIFIERS \
    QT_QPA_PLATFORM=wayland WAYLAND_DISPLAY=taketest \
    HOME=/home/xieyizhou XDG_RUNTIME_DIR=/run/user/1000 \
    DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus \
    /usr/lib/aarch64-linux-gnu/libexec/kactivitymanagerd > $LOGD/kactivitymanagerd.log 2>&1 &
for i in $(seq 1 10); do
    runuser -u xieyizhou -- env DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus \
        gdbus call --session --dest org.freedesktop.DBus --object-path /org/freedesktop/DBus \
        --method org.freedesktop.DBus.ListNames 2>/dev/null | grep -q org.kde.ActivityManager && break
    sleep 1
done
runuser -u xieyizhou -- env DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus \
    gdbus call --session --dest org.freedesktop.DBus --object-path /org/freedesktop/DBus \
    --method org.freedesktop.DBus.ListNames 2>/dev/null | grep -q org.kde.ActivityManager \
    || echo "WARN: kactivitymanagerd not on bus, plasmashell may abort (see kactivitymanagerd.log)"
nohup runuser -u xieyizhou -- env -u DISPLAY -u QT_IM_MODULE -u GTK_IM_MODULE \
    -u SDL_IM_MODULE -u GLFW_IM_MODULE -u XMODIFIERS \
    WAYLAND_DISPLAY=taketest \
    HOME=/home/xieyizhou XDG_RUNTIME_DIR=/run/user/1000 \
    DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus \
    QT_QPA_PLATFORM=wayland \
    /usr/bin/plasmashell --replace > $LOGD/plasma.log 2>&1 &
# ---- 托盘亮度/电池（09-24 三根因定修）----
# 1) 容器 /sys 挂成 ro → backlighthelper 写亮度 EROFS；remount rw 解决
# 2) 无 logind active session → polkit 默认拒 org.kde.powerdevil.backlighthelper.*
# 3) DRM 会话不走 startplasma，powerdevil 守护根本没人拉
mount -o remount,rw /sys 2>/dev/null || echo "WARN: /sys remount failed, brightness slider will be read-only"
cat > /etc/polkit-1/rules.d/61-powerdevil-backlight.rules <<'EOF'
polkit.addRule(function(action, subject) {
    if (action.id.indexOf("org.kde.powerdevil.backlighthelper.") === 0 &&
        subject.user === "xieyizhou") {
        return polkit.Result.YES;
    }
});
EOF
systemctl try-restart polkit 2>/dev/null
PDEV=$(ls /usr/lib/*/libexec/org_kde_powerdevil 2>/dev/null | head -1)
[ -n "$PDEV" ] && nohup runuser -u xieyizhou -- env -u DISPLAY -u QT_IM_MODULE \
    WAYLAND_DISPLAY=taketest \
    HOME=/home/xieyizhou XDG_RUNTIME_DIR=/run/user/1000 \
    DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus \
    QT_QPA_PLATFORM=wayland \
    "$PDEV" > $LOGD/powerdevil.log 2>&1 &
# 任务栏点击启动应用走 xdg-desktop-portal；不带 KDE 环境起来的话只有 gtk 后端
nohup runuser -u xieyizhou -- env -u DISPLAY -u QT_IM_MODULE -u GTK_IM_MODULE \
    -u SDL_IM_MODULE -u GLFW_IM_MODULE -u XMODIFIERS \
    WAYLAND_DISPLAY=taketest XDG_CURRENT_DESKTOP=KDE XDG_SESSION_TYPE=wayland \
    HOME=/home/xieyizhou XDG_RUNTIME_DIR=/run/user/1000 \
    DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus \
    QT_QPA_PLATFORM=wayland \
    /usr/libexec/xdg-desktop-portal > $LOGD/portal.log 2>&1 &
touch $DIR/takeover.ok
$DIR/bin/setbright 2048 > /dev/null 2>&1
echo "DESKTOP-UP $(date +%T) kwin pid $KPID"

# ---- 5) 容器接管 WiFi：NetworkManager 模式（DRM 桌面设置里可直接点热点、密码持久化） ----
# 备份安卓策略路由后再动 rule——netd 已死没人管；desk-stop 会原样还原再 start。
ip rule save > /run/desk-ip-rules.bak 2>/dev/null
pkill -9 -f 'wpa_supplicant.*desk-wifi' 2>/dev/null
pkill -x dhcpcd 2>/dev/null
if command -v NetworkManager >/dev/null 2>&1; then
    ip link set wlan0 down; sleep 1; ip link set wlan0 up
    # 安卓把 main 表摘了、全塞 fwmark→1015，NM 的 DHCP 不吃这套 → 恢复内核标准三表
    ip rule flush
    ip rule add pref 0 table local        2>/dev/null
    ip rule add pref 100 table main       2>/dev/null
    ip rule add pref 32766 table default  2>/dev/null
    ip -4 addr flush dev wlan0 2>/dev/null
    cat > /run/nm-drm.conf <<'EOF'
[main]
plugins=keyfile
[connectivity]
uri=
[keyfile]
# 只管真 WiFi 网卡；p2p0 也报 wifi 型，托管它=列表每个热点出现两遍且 p2p0 份永远连不上（09-23 实测）
unmanaged-devices=except:type=wifi;interface-name:p2p0
EOF
    mkdir -p /run/NetworkManager
    # NM 靠 D-Bus 激活 wpa_supplicant.service 拉起扫描/认证进程——它可以 disabled 但绝不能 masked
    systemctl unmask wpa_supplicant.service 2>/dev/null
    # plasma-nm 点击连接会被 polkit 拒（"Not authorized to control networking"，
    # 容器里无 logind active 会话）→ 给本用户放行 NM 动作（仅本机 DRM 场景）
    mkdir -p /etc/polkit-1/rules.d
    cat > /etc/polkit-1/rules.d/60-nm-drm.rules <<'EOF'
polkit.addRule(function(action, subject) {
    if (action.id.indexOf("org.freedesktop.NetworkManager") === 0 && subject.user === "xieyizhou")
        return polkit.Result.YES;
});
EOF
    systemctl try-restart polkit 2>/dev/null
    # 09-24 实锤：kill 段的 `systemctl stop wpa_supplicant` 之后，NM 1.54 有时整个会话
    # 都不发起 fi.w1.wpa_supplicant1 的 D-Bus 激活（journal 零激活请求，wlan0 永久
    # unavailable，桌面里搜不到任何热点）。不再赌它的懒激活：起 NM 前先把 supplicant 拉活。
    systemctl reset-failed wpa_supplicant.service 2>/dev/null
    systemctl start wpa_supplicant.service 2>/dev/null
    # 09-24 10:10 轮再实锤：supplicant 先起、bus 名已持有，NM 依旧整场不 attach
    # （journal 里连一条 supplicant 行都没有）→ 预拉活只是必要不充分。开 SUPPLICANT/
    # DEVICE 域 DEBUG 抓 attach 失败的第一现场（--log-level 是上限，未点名的域仍 INFO）。
    nohup NetworkManager --config /run/nm-drm.conf --no-daemon \
        --log-level=DEBUG --log-domains=SUPPLICANT:DEBUG,DEVICE:DEBUG,WIFI:DEBUG,WIFI_SCAN:DEBUG,RFKILL:DEBUG \
        > $LOGD/nm-drm.log 2>&1 &
    for i in $(seq 1 15); do nmcli status >/dev/null 2>&1 && break; sleep 1; done
    nmcli radio wifi on 2>/dev/null   # 清掉可能的软阻塞（上一轮残留状态）
    # 首轮引导：NM 刚起扫描缓存是空的，先 rescan 再带重试连接；
    # 成功即自动落 keyfile(0600)，以后自连、plasma-nm 面板可改
    if [ -n "$CUR_SSID" ] && [ -n "$CUR_PSK" ]; then
        (
            for t in 1 2 3 4 5; do
                sleep 3
                nmcli -g NAME connection list 2>/dev/null | grep -qxF "$CUR_SSID" && break
                nmcli device wifi rescan 2>/dev/null
                nmcli device wifi connect "$CUR_SSID" password "$CUR_PSK" >> $LOGD/nm-drm.log 2>&1 && break
            done
        ) &
    fi
    OK=0
    # 旧检查 `nmcli device status wlan0` 是非法语法（status 不接受设备名参数），
    # 永远返回空 → 每轮都误报 NET-FAILED（09-23 晚其实已连上并拿到 DHCP，lease 为证）。
    # LC_ALL=C 钉死英文，防中文 locale 把 "connected" 翻成 "已连接" 再次错过匹配。
    for i in $(seq 1 60); do
        [ "$(LC_ALL=C nmcli -t -f DEVICE,STATE devices 2>/dev/null | grep '^wlan0:' | cut -d: -f2)" = "connected" ] && { OK=1; break; }
        sleep 1
    done
    if [ "$OK" = 1 ]; then
        echo "WIFI-ASSOC OK (NM) $(date +%T)"
        NET=0
        for i in 1 2 3; do
            ping -c 2 -W 2 223.5.5.5 >/dev/null 2>&1 && { NET=1; break; }
            sleep 2
        done
        if [ "$NET" = 1 ]; then
            echo "NET-TAKEOVER OK (NM) $(date +%T)"
        else
            echo "--- egress diagnosis (NM) ---"
            ip route show; nmcli device show wlan0 | head -20
            echo "NET-EGRESS-FAIL (NM) $(date +%T): desktop kept"
        fi
    else
        echo "--- NM diagnosis ---"
        # REASON 列直接给出 unavailable 的第一因（supplicant 相关 vs rfkill vs 驱动）
        LC_ALL=C nmcli -t -f DEVICE,TYPE,STATE,REASON devices 2>&1 | grep -vE '^(lo|dummy|p2p)' | head -8
        nmcli -t -f DEVICE,STATE devices 2>&1 | head -5
        tail -n 60 $LOGD/nm-drm.log
        echo "NET-FAILED (NM) $(date +%T): desktop kept, NO network"
    fi
else
# ---- 5L) legacy 手管段（NM 未安装时的 fallback，原 wpa+dhcpcd+表1015 方案） ----
if [ -f "$WIFI_GEN" ] || [ -f "$WIFI_CONF" ]; then
[ -f "$WIFI_GEN" ] && WIFI_CONF="$WIFI_GEN"
pkill -f 'wpa_supplicant.*desk-wifi' 2>/dev/null
pkill -x dhcpcd 2>/dev/null
sleep 1
ip link set wlan0 down; sleep 1; ip link set wlan0 up
mkdir -p /run/wpa-takeover
/usr/sbin/wpa_supplicant -i wlan0 -c "$WIFI_CONF" -P /run/wpa-takeover.pid > /run/wpa-takeover.log 2>&1 &
OK=0
for i in $(seq 1 30); do
    sleep 1
    wpa_cli -p /run/wpa-takeover -i wlan0 status 2>/dev/null | grep -q "wpa_state=COMPLETED" && { OK=1; break; }
done
if [ "$OK" != 1 ]; then
    echo "--- wpa diagnosis ---"
    wpa_cli -p /run/wpa-takeover -i wlan0 status
    tail -n 25 /run/wpa-takeover.log
    # 网络尽力而为：关联失败不连坐桌面（安卓已 stop，网络要等 desk-stop/回滚才恢复）
    pkill -f 'wpa_supplicant.*desk-wifi' 2>/dev/null
    echo "NET-FAILED $(date +%T): desktop kept, NO network (SSID/PSK 没对上？返回安卓再试)"
fi
if [ "$OK" = 1 ]; then
echo "WIFI-ASSOC OK $(date +%T), now DHCP"
# 安卓 netd 留的旧地址是 noprefixroute（main 表没直连路由，默认路由会被拒
# "Nexthop has invalid gateway"）→ 先冲干净，让 dhcpcd 完整接管；
# 兜底路由必须带 onlink 跳过网关可达性检查。
ip addr flush dev wlan0
dhcpcd -k wlan0 2>/dev/null
pkill -9 -x dhcpcd 2>/dev/null; sleep 1
dhcpcd -4 -w -t 20 wlan0 || echo "dhcpcd exited rc=$?"
sleep 1
ip -4 route show default dev wlan0 | grep -q default || ip -4 route replace default via $GW dev wlan0 onlink
# 动态取租约网段+网关（换网免改脚本）
LEASED=$(ip -4 -br addr show wlan0 | awk '{print $3}' | head -1)
DYN_GW=$(ip -4 route show default dev wlan0 | awk '{print $3; exit}')
if [ -n "$LEASED" ]; then
    NETV=$(python3 -c "import ipaddress,sys; a=ipaddress.IPv4Interface(sys.argv[1]); print(a.network)" "$LEASED" 2>/dev/null)
fi
[ -n "$DYN_GW" ] && GW="$DYN_GW"
# 安卓删掉了 "lookup main" 规则，本机所有包（含 root ping）都走
# "fwmark 0/0xffff lookup 1015"；link down/up 又清空了 1015 → main 配再好也不通。
ip -4 route replace ${NETV:-172.16.30.0/22} dev wlan0 table 1015
ip -4 route replace default via $GW dev wlan0 table 1015 onlink
ip -4 addr show dev wlan0
ip -4 route show
rm -f /etc/resolv.conf
printf 'nameserver 223.5.5.5\nnameserver 114.114.114.114\n' > /etc/resolv.conf
NET=0
for i in 1 2 3; do
    ping -c 2 -W 2 223.5.5.5 >/dev/null 2>&1 && { NET=1; break; }
    sleep 2
done
if [ "$NET" != 1 ]; then
    echo "--- egress diagnosis ---"
    ip route show table all | head -n 30
    cat /etc/resolv.conf
    echo "NET-EGRESS-FAIL $(date +%T): desktop kept, egress broken (路由/表1015 问题?)"
else
    echo "NET-TAKEOVER OK $(date +%T)"
fi
fi
else
    echo "NET-SKIPPED $(date +%T): 无可用 wifi 配置(安卓 SSID/PSK 没读到)，只起桌面"
fi
fi

# ---- 6) 收尾：取证收割机 + 状态 ----
DEV=$DEV nohup bash $DIR/scripts/dmesg-harvester.sh > /dev/null 2>&1 &
adb -s "$DEV" shell "su -c 'free -m | head -2'"
echo "=== DESK-TAKEOVER DONE $(date +%T): kwin pid $KPID, plasma up, net via container wpa+dhcpcd ==="
