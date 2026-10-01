#!/bin/bash
# desk-stop.sh v2 — 结束 desk-takeover.sh 的全自动接管，把显示+WiFi 全部还给安卓。
# v1 教训(22:45 轮)：① pkill 模式与实际 cmdline 不符，kwin 没死→SF 抢不回 DRM master；
# ② 脚本没和终端脱钩，plasma 组件被杀时 konsole 一起没了→`start` 没执行→黑屏+断网。
# v2 对策：主体 setsid 脱离终端后台跑，前台只 tail 日志；杀桌面用"模式+验证重试+fuser兜底"；
# 拉起安卓后轮询 init.svc，不达标就补刀再 start。
ROOT="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
DIR=$ROOT
LOGD=${LOG_DIR:-$ROOT/logs}   # 兜底也在仓库自己目录里，不假设父目录叫什么
# ---- 用户与路径参数（09-30 参数化，为分发而做；本机没有 conf 时等价于原硬编码）----
# 有 /etc/drm-takeover.conf 就读它（由 drm-tui 安装器生成）。
# 这里**不猜"当前用户"**：接管必须以桌面用户身份跑（runuser / HOME / polkit subject / XDG_RUNTIME_DIR
# 全都按它来）。root 终端里 id -un == root，猜错的结果是"kwin 以 root 起 → DRM Xwayland 拒绝连接
# + polkit 规则对不上 → 亮度/NM 全拒"，比直接报错难查得多。
DRM_CONF_FILE=${DRM_CONF_FILE:-/etc/drm-takeover.conf}
[ -r "$DRM_CONF_FILE" ] && . "$DRM_CONF_FILE"
DRM_USER=${DRM_USER:-xieyizhou}
DRM_UID=${DRM_UID:-1000}
DRM_HOME=${DRM_HOME:-/home/xieyizhou}
DRM_RT=/run/user/$DRM_UID

# ---- 权限闸门：必须在**任何动作之前**（尤其在建自脱钩与 stop 安卓之前）----
# 10-01 新容器实测：以普通用户跑起来时 mknod/chmod/ln 全部 Permission denied，
# 但脚本照往下走 —— 真的把安卓显示栈 stop 了（ANDROID-STOP），等 kwin 起不来才回滚，
# 用户白白经历几十秒黑屏。没有 root 就一步都不许走。
if [ "$(id -u)" != 0 ]; then
    echo "NEED-ROOT: 接管/交还必须以 root 运行（要 mknod 设备节点、写 udev 规则、stop/start 安卓服务）。" >&2
    echo "  请用：sudo bash $0" >&2
    exit 1
fi

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

# ⚠ 这里**必须重试**：adb server 冷启动后第一次 `adb devices` 是空表，一锤子买卖会把
# "通道正常"判成"通道没了" ⇒ 本脚本直接 exit，安卓不会被交还，用户面对的就是黑屏。
# （10-01 14:18 新容器三轮 NO-ADB-DEVICE 就是这个形状；exit 本身是对的——无 adb 时继续往下
#   只会把 Linux 桌面杀光又救不回安卓——但判据不能建在一次冷表上。）
adb start-server >/dev/null 2>&1
DEV=""
for _adb_try in 1 2 3 4 5; do
    DEV=$(timeout 12 adb devices | awk '$2=="device"{print $1; exit}')
    [ -n "$DEV" ] && break
    sleep 2
done
[ -n "$DEV" ] || { echo "NO-ADB-DEVICE 原始表："; timeout 12 adb devices -l 2>&1 | sed 's/^/    /'; echo "NO-ADB-DEVICE"; exit 1; }
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
    pkill -9 -f "bt-keepalive[.]sh" 2>/dev/null   # 必须先于杀桥：否则桥一被杀，看门狗立刻把它当"没在跑"重拉
    # 桥在**安卓的 PID ns**里（它是 adb shell 起起来的），容器侧 pgrep/pkill 永远看不见它 ——
    # 老写法 `pkill -9 -x bthci-bridge` 在这条保命路径上是彻底的空操作（09-30 实测：容器侧
    # pgrep 为空、/proc/5751 不存在，而安卓侧同一个 pid 活得好好的）。必须走 run 到安卓侧，
    # 并且按 comm 匹配（不带 -x：部署名 bthci-bridge-v2 会漏；不带 -f：su -c 的壳会自匹配）。
    run 'for p in $(pgrep bthci-bridge); do kill -9 $p; done'   # 进程退→tty 关→内核自动注销 hci0
    pkill -9 -f "aa-feeder.sh" 2>/dev/null    # A 路音频：容器 feeder + 安卓 argsloop sink
    pkill -9 -f "pc-keyd.py" 2>/dev/null         # pc-keyd 的 uinput 键盘会令安卓常驻物理键盘通知（09-27）；轮内没起它则无操作
    WDEV=$(timeout 12 adb devices | awk '$2=="device"{print $1; exit}')
    [ -n "$WDEV" ] && timeout 12 adb -s "$WDEV" shell "su -c 'pkill -x argsloop'" 2>/dev/null
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
# supplicant 的收尾：**先 TERM、等它自己退，超时才 -9**。
# cfg80211 的 scheduled-scan `Match` 是它注册进驱动的，只有它自己退出时才会注销。
# 直接 -9 ⇒ 内核里那份 Match 没人清 ⇒ **同一开机的下一轮**新 supplicant 报
# `Match already configured` + `Could not set interface wlan0 flags (UP): Invalid argument`，
# 整轮 WiFi 起不来。**注意别高估这条**：可比的 23 轮里 7 个失败轮有 4 个两种签名都没有，
# Match 只覆盖 2 轮 ⇒ 这是卫生修复，不是第二轮解药（失败轮真签名＝内核拒绝把 wlan0 拉 UP，
# 明细见工作总结 5.33①③④）。
# 只按**进程名**取（不用 `pgrep -f 'wpa_supplicant -u'`）：-f 匹配的是整条命令行，
# 会把"命令行里正好提到过这串字"的调用方 shell 一起算进来 —— 09-25 实测这么干把自己
# 所在的会话打成了 SIGTERM（rc=143）。容器 pidns 里看不到安卓那份（实测无 zygote/
# surfaceflinger/netd），所以 -x 既杀得准也不会误伤安卓。
wpa_pids() {
    local p out=""
    # pid 文件可能是**上一轮的陈旧值**，那个号现在可能属于别的进程 ⇒ 先验名字再收
    if [ -f /run/desk-wpa.pid ]; then
        p=$(cat /run/desk-wpa.pid 2>/dev/null)
        [ -n "$p" ] && [ "$(cat /proc/$p/comm 2>/dev/null)" = "wpa_supplicant" ] && out="$p "
    fi
    for p in $(pgrep -x wpa_supplicant 2>/dev/null); do out="$out$p "; done
    printf '%s\n' "$out"
}
wpa_stop_graceful() {
    # 先记下"我要杀的是哪些 pid"，等的时候只查这批（判生死不能靠 -f，见上）。
    local pids p left
    pids="$(wpa_pids)"
    [ -n "${pids// /}" ] || return 0          # 本来就没有实例：秒返回，别白付 8s
    kill -TERM $pids 2>/dev/null
    for _ in 1 2 3 4 5 6 7 8; do
        left=""
        for p in $pids; do kill -0 "$p" 2>/dev/null && left="$left $p"; done
        [ -z "$left" ] && return 0
        sleep 1
    done
    echo "WPA-GRACEFUL 超时未退：$left"
    return 1
}
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
    pkill -9 -f "pc-keyd.py" 2>/dev/null         # 09-27 默认关+交还清理：root 实例残留会让通知活到 anland（08:44 通知实证）
    # Xwayland 由 kwin --xwayland 拉起（09-24 接入），是 kwin 的子进程；kwin 被 -9 时
    # 它未必跟着退，残留会占住 display 号与 /tmp/.X11-unix/X<n> 死套接字
    pkill -9 -x Xwayland
    # 容器与安卓共享 netns → wlan0 只能有一个主人。09-24 起 supplicant 是自拉 nohup 版
    # （cmdline `wpa_supplicant -u -t -O ...`，不含 desk-wifi），旧模式永远杀不到它，
    # 残留进程攥着 nl80211/D-Bus 控制权 → 回安卓后 WiFi 开关点了没反应，只能重启（09-24 两次实测）。
    if ! wpa_stop_graceful; then
        echo "WPA-TERM TIMEOUT 8s -> 补 -9（下一轮靠 desk-takeover 的 WIFI-PRECLEAR 兜残留 Match）"
        # 按名字补杀，不用 -f：-f 会连"命令行里提到这串字"的调用方一起命中（见 wpa_pids 头注）
        pkill -9 -x wpa_supplicant 2>/dev/null
    fi
    rm -f /run/desk-wpa.pid
    pkill -9 -f 'strace.*-strace.txt'      # 接管期的 wpa/NM strace 尾巴
    pkill -9 -f "nm-drm.conf"
    pkill -x NetworkManager
    # udevd 活着就会在安卓重建 wlan0 的 uevent 上二次改名（wlp1s0，09-24 事故主角）；
    # 接管期它只是 NM 的工具，交还后必须闭嘴。下一轮 desk-takeover 会重新拉起。
    pkill -9 -x systemd-udevd
    pkill -9 -f "input-node-sync.sh"   # /dev/input 节点同步器（setsid 起的，模式杀不到自己）
    # （09-25 已撤销"接管轮里把 udevd 拉成真单元"那套：隔离实验显示它一来 WiFi 就炸、
    #   返回链也会卡死；见 desk-takeover 1b) 的注释。这里只保留原有的 pkill。）
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
# 顺序：先停看门狗（它会替桥"复活"），再杀桥。
# 看门狗是容器侧常驻进程，交还后若还活着就会跟安卓自己的蓝牙栈抢 HAL 客户端位（5.30 事故家族）。
pkill -f "bt-keepalive[.]sh" 2>/dev/null
# 桥在安卓 PID ns：容器侧 pkill 是空操作，一律走 run（见上面保命看门狗那条注释）
run 'for p in $(pgrep bthci-bridge); do kill $p; done'
sleep 2
# 轮内"蓝牙关不掉"的总线策略只对本轮有效，交还即撤（轮外桌面就该能自己关蓝牙）。
# 实测过这条 deny 不 ReloadConfig 也会随文件消失而失效，但那是"碰巧"，这里显式 Reload 一次。
if [ -f /etc/dbus-1/system.d/61-bluez-drm-lock.conf ]; then
    rm -f /etc/dbus-1/system.d/61-bluez-drm-lock.conf
    dbus-send --system --dest=org.freedesktop.DBus /org/freedesktop/DBus \
        org.freedesktop.DBus.ReloadConfig >/dev/null 2>&1 \
        && echo "BT-LOCK REMOVED $(date +%T): 总线策略已撤（不重启 dbus，避免打断 NM/kded）" \
        || echo "BT-LOCK REMOVE-FAIL $(date +%T): 文件已删但 ReloadConfig 没应答 ⇒ 以自检为准（见下）"
fi
pkill -x NetworkManager 2>/dev/null
# A 路音频：交还安卓前放掉我们的常驻 sink（安卓侧进程名 argsloop，占着 deep_buffer/speaker 端口与 patch）
# 和容器侧 feeder，否则 audioserver 重启抢不到 HAL 输出流。
pkill -f "aa-feeder.sh" 2>/dev/null
timeout 12 adb -s "$DEV" shell "su -c 'pkill -x argsloop'" 2>/dev/null
# NM 经 D-Bus 激活的 wpa_supplicant 会赖在总线上；只停容器 systemd 的实例（安卓那侧不受影响）
systemctl stop wpa_supplicant.service 2>/dev/null
ip -4 addr flush dev wlan0 2>/dev/null
# 【09-25 缺陷②修复】交还要连"射频状态"一起清：轮内 plasma-nm 关 WiFi = 容器 NM 把
# rfkill(wlan) soft-block，NM 死后没人解 → 回 anland 安卓"WiFi 打不开"（17:1x 实测
# rfkill1 soft=1 而驱动完好）。**只碰 type=wlan，绝不碰 bt_power**（蓝牙电源红线）。
for r in /sys/class/rfkill/rfkill*; do
    [ "$(cat $r/type 2>/dev/null)" = wlan ] || continue
    if [ "$(cat $r/soft 2>/dev/null)" = 1 ]; then
        echo 0 > "$r/soft" 2>/dev/null && echo "RFKILL-UNBLOCK $(basename $r) $(date +%T)" || echo "RFKILL-UNBLOCK-FAIL $(basename $r) $(date +%T)"
    fi
done
if [ -f /run/desk-ip-rules.bak ]; then
    # desk-takeover 的 NM 段 flush 过 rule；原样还原，netd 回来会补建自己的规则
    ip rule flush; ip rule restore < /run/desk-ip-rules.bak && echo "ip-rule restored from bak"
fi
# 【09-25 傍晚 第二次同类死亡实锤，见工作总结 5.36】这里原有的 `ip link set wlan0 down`
# 与 desk-takeover 的 up 是同一把枪的**交接方向**那一击：16:30:39 我们 down（peach 当时
# 已在 idle 半初始化态，deinit 报 "was not initialized"×2）→ 16:30:41 start →
# ~40s 后安卓自己 wifi-on 上电 → `cnss: Failed to start MHI err=-110` →
# `Recovery is already in progress → ASSERT 2436` → netlink/uevent 全塞，
# adbd 陪葬（iw 超时、svc rc=255）、system_server 起不全 = 黑屏，只能强启。
# 判据已升级成红线：**idle 态 peach 上，down 之后的任何一次 up（不分主人、间隔 40s 也炸）**
# 都会进这个洞 ⇒ 交还也不做 admin 变更：接口保持 UP 原样还给安卓，L3 已清、rule 已还原。
ip -o link show wlan0 2>/dev/null | sed -n 's/.*<\([^>]*\)>.*/WLAN-ADMIN-AT-HANDOVER flags=\1/p'
# 交还前的残留检查（必须在 4b 重启 anland 会话之前取，否则会把 anland 自己正常拉起的
# NM/supplicant 误报成泄漏）：容器里还有 wpa_supplicant 活着 = wlan0 主人没换干净
LEFT=$(pgrep -x wpa_supplicant | tr '\n' ' ')
# 打 cmdline 时也按名字取号（`pgrep -fa wpa_supplicant` 会把"命令行里提到这串字"的
# 调用方一起列进来，09-25 实测过这个坑）
[ -n "$LEFT" ] && echo "WIFI-HANDOVER LEAK: 容器侧仍有 pid=$(echo $LEFT) cmdline=$(for p in $LEFT; do tr -d '\0' < /proc/$p/cmdline; done)"
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
# ---- 4f) VKMARK-ASYNC 清理（desk-takeover 2d 段写入的 kwinrc AllowTearing；全局文件必须清，
#          否则 anland 的 kwin 也带 tearing 许可。同样 chown 回用户，防 root 属主残留）----
KRC="$DRM_HOME/.config/kwinrc"
if [ -f "$KRC" ]; then
    kwriteconfig6 --file "$KRC" --group Compositing --key AllowTearing --delete
    # 座位 IM 无需恢复：09-29 起两模式统一 fcitx5，交还后 anland 自拉的会话继承同值。
    chown "$DRM_USER:$DRM_USER" "$KRC"
    echo "TEARING-CONFIG CLEANED (kwinrc AllowTearing 已删)"
fi
unset KRC

# ---- 4b1) 把安卓存储接回容器（后台跑，别拖慢 anland 复活）：交还时安卓重启框架会 mount
#           出**新的** fuse 超级块，容器 boot 时 bind 的旧那份从此 ENOTCONN —— 表现为
#           "拒绝访问"，改权限无效（根因与判据见 工作总结 §3.12）。设备侧脚本自己等源活
#           了再动手，这里只负责触发；判据行落在 $LOGD/storage-fix.log。
nohup bash $ROOT/scripts/storage-fix.sh 90 >>"$LOGD/storage-fix.log" 2>&1 </dev/null &
echo "STORAGE-FIX launched bg pid=$! log=$LOGD/storage-fix.log"

# 4b) 复活 anland 会话。RELAUNCH_ANLAND 由 /etc/drm-takeover.conf 控制（drm-tui 设置页里那个开关）：
#     默认 1＝交还后自动把 Linux 桌面放回安卓里（09-23 白屏坑的修法，绝大多数情况要留着）；
#     设成 0＝交还后停在纯安卓，用户下次得从 drm-tui 里手动「重启 anland」。
if [ "${RELAUNCH_ANLAND:-1}" != 1 ]; then
    echo "ANLAND-SKIP $(date +%T)：RELAUNCH_ANLAND=0，交还后不自动拉起 anland（下次进 DRM 接管会重新按 conf 处理）"
elif [ -x /usr/local/bin/startanland-kde.sh ] || [ -f /usr/local/bin/startanland-kde.sh ]; then
    runuser -u "$DRM_USER" -- bash -c 'nohup /usr/local/bin/startanland-kde.sh > /tmp/anland-restart.log 2>&1 &' \
        && echo "anland session relaunched"
else
    echo "ANLAND-MISS $(date +%T)：没有 /usr/local/bin/startanland-kde.sh，交还后不会有任何 Linux 桌面（这不是正常状态）"
fi

# ---- 4b2) 蓝牙交还确认：看门狗与桥都必须已经死干净（桥活着=容器还占着 hci0 的 tty，
#          安卓自己的蓝牙栈起不来；实测安卓开机/重启服务时会自己重新 enable）----
KALEFT=$(pgrep -f "bt-keepalive[.]sh" | tr '\n' ' ')
if [ -n "$KALEFT" ]; then
    pkill -9 -f "bt-keepalive[.]sh"; sleep 1
    echo "BT-LEAK: 看门狗没死($KALEFT) → 已强杀（不先杀它，下面的重桥会立刻把桥再拉起来）"
fi
BTLEFT=$(run 'pgrep bthci-bridge' | tr -d '\r' | grep -E '^[0-9]+$' | tr '\n' ' ')
if [ -n "${BTLEFT// /}" ]; then
    run 'for p in $(pgrep bthci-bridge); do kill -9 $p; done'; sleep 1
    BTSTILL=$(run 'pgrep bthci-bridge' | tr -d '\r' | grep -E '^[0-9]+$' | tr '\n' ' ')
    if [ -n "${BTSTILL// /}" ]; then
        echo "BT-LEAK-STILL $(date +%T): 强杀后安卓侧仍有桥 pids=${BTSTILL}（hci0 还被容器占着，安卓蓝牙栈起不来；手杀：adb shell su -c 'kill -9 ${BTSTILL// /}'）"
    else
        echo "BT-LEAK: 桥没死干净($BTLEFT) → 已强杀（hci0 随 tty 关闭自动注销）"
    fi
elif [ -z "$KALEFT" ]; then
    echo "BT-HANDOVER OK $(date +%T): 安卓侧无残留桥、容器侧无残留看门狗"
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

# ---- 4g) GPUFLOOR 还原（desk-takeover 1c 段钉的 GPU min_pwrlevel；共享内核必须还原，
#          否则钉死的频率泄漏给 anland/安卓。orig 文件格式："<mode> <min_pwrlevel>"，
#          落在 /run/desk-gpufreq.orig。1c 段把节点 chmod 成 0644 才能写，还原时按原 mode 复原）----
if [ -f /run/desk-gpufreq.orig ]; then
    read -r GM GO < /run/desk-gpufreq.orig
    [ -z "$GO" ] && { GO="$GM"; GM=444; }   # 兼容旧的单值格式
    case "$GO" in
    *[!0-9]*|"") rm -f /run/desk-gpufreq.orig ;;
    *) case "$GM" in *[!0-9]*|"") GM=444 ;; esac
       GK=/sys/class/kgsl/kgsl-3d0/min_pwrlevel
       # 先 chmod 解锁再写：vendor 可能已把 mode 改回 0444（拦路是 kernfs DAC，见 takeover 1c 注释）
       GOUT=$(run "chmod 0644 $GK; echo $GO > $GK; chmod $GM $GK; cat $GK" | tr -d '\r' | awk 'END{print}')
       rm -f /run/desk-gpufreq.orig
       if [ "$GOUT" = "$GO" ]; then
           echo "GPUFLOOR-RESTORE OK min_pwrlevel=$GO (mode->$GM)"
       else
           echo "GPUFLOOR-RESTORE FAIL 回读=$GOUT 预期=$GO ⇒ GPU 可能还钉着（泄漏给 anland），手工：chmod 0644 $GK; echo $GO > $GK; chmod $GM $GK"
       fi ;;
    esac
fi

# ---- 4h) PERFMAX 还原（desk-takeover 1d 段；无记录就跳过）----
# 顺序不能换：先让 perfmax.sh 的重申循环退出，再 restore，否则 restore 刚写完就被循环写回顶档。
if [ -n "$(run "test -s /data/local/tmp/perfmax.orig && echo HASREC")" ]; then
    run "sh /data/local/tmp/perfmax.sh stop" >/dev/null 2>&1
    sleep 3
    run "sh /data/local/tmp/perfmax.sh restore" | tail -n 8
else
    # 循环可能在跑但记录已丢失（例如上一轮异常中断）——至少把循环关掉
    run "test -f /data/local/tmp/perfmax.orig || rm -f /data/local/tmp/perfmax.orig; : > /data/local/tmp/perfmax.stop; pkill -f \"sh /data/local/tmp/perfmax\" >/dev/null 2>&1; echo PERFMAX-LOOP-KILLED" >/dev/null 2>&1
fi

# ---- 5) 结果取证 ----
sleep 10
run "getprop init.svc.surfaceflinger; getprop init.svc.zygote; getprop init.svc.wpa_supplicant"
run "dumpsys power 2>/dev/null | grep -m1 -E \"mWakefulness=\" ; dumpsys display 2>/dev/null | grep -m1 -E \"mScreenState=\""
timeout 8 ping -c 2 -W 1 223.5.5.5 >/dev/null 2>&1 && echo "NET RESTORED VIA ANDROID" || echo "NET STILL DOWN after start"
echo "=== DESK-STOP DONE $(date +%T) ==="
