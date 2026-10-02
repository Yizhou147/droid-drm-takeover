#!/bin/bash
# desk-takeover.sh — 全自动无网接力：stop 安卓 → kwin DRM 持屏 + Plasma 桌面 → 容器接管 WiFi。
# 顺序按用户要求：先桌面，再网络。全程不需要我在线（adb 走本机 emulator-5554 通道）。
# 任一关键步失败 → 自动回滚（恢复安卓全家，含 system_suspend 显式拉起，防 Scout 重启）。
ROOT="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
DIR=$ROOT
LOGD=${LOG_DIR:-$ROOT/logs}   # 兜底也在仓库自己目录里，不假设父目录叫什么
mkdir -p "$LOGD"
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
# ---- 必须清掉 anland 那组环境变量（10-01 测试容器实锤）----
# DroidSpaces 的 anland 集成会把 ANLAND=1 / ANLAND_SOCKET / ANLAND_DRM_DEVICE 写进 /etc/environment，
# 而 sudo 的 env_reset 之后 PAM 仍会重读 /etc/environment ⇒ 这些值会一路传到 kwin。
# kwin（打过补丁的那份）看到 ANLAND=1 就自动选 **anland 后端**而不是 DRM：
# 表现是 kwin 活着、wayland-info 也过、但 kwinatomic.log 里 0 条 ATOMIC、面板什么都不显示，
# 而脚本以为成功 → 不回滚 → 只能强制重启。接管轮里 anland 后端没有任何意义，直接清掉。
unset ANLAND ANLAND_SOCKET ANLAND_DRM_DEVICE ANLAND_SKIP_IMPLICIT_SYNC_WAIT

# ---- 权限闸门：必须在**任何动作之前**（尤其在建自脱钩与 stop 安卓之前）----
# 10-01 新容器实测：以普通用户跑起来时 mknod/chmod/ln 全部 Permission denied，
# 但脚本照往下走 —— 真的把安卓显示栈 stop 了（ANDROID-STOP），等 kwin 起不来才回滚，
# 用户白白经历几十秒黑屏。没有 root 就一步都不许走。
if [ "$(id -u)" != 0 ]; then
    echo "NEED-ROOT: 接管/交还必须以 root 运行（要 mknod 设备节点、写 udev 规则、stop/start 安卓服务）。" >&2
    echo "  请用：sudo bash $0" >&2
    exit 1
fi


# ---- 自脱钩（09-23 黑屏事故教训，同 desk-stop v2）：快捷方式从桌面 konsole 进来时，
#      konsole 是将被本脚本杀掉的 kwin 的客户端；kwin 一死 pty 关闭，前台脚本陪葬，
#      而此时安卓已 stop → 两头全黑。主体必须 setsid 脱离终端。 ----
# ---- 10-02 升级（§12.39 三次静默死亡事故）：setsid 只换会话不换 cgroup —— anland /
#      DRM 会话收尾时 logind 按 cgroup 收割整棵树，setsid 过的脚本照样死（16:41/16:59/
#      17:02 三次黑屏的直接死因）。所以先用 system 级 `systemd-run --scope` 把自己挪进
#      system.slice：任何用户会话拆除都够不着；输出照旧落日志，终端死活无关。
#      systemd-run 不可用再回落 setsid nohup（旧行为）。 ----
if [ -z "$DESKSTART_ID" ]; then
    DESKSTART_ID="$$.start"
    export DESKSTART_ID
    if command -v systemd-run >/dev/null 2>&1; then
        # --scope 会等真身跑完，所以放后台：$! 陪着整轮活着，tail 锚得住
        systemd-run --scope --collect --unit="drm-round-$$" \
            bash "$0" >>"$LOGD/desk-takeover.log" 2>&1 </dev/null &
        CHILD=$!
        echo "（轮已挪入 system 级 scope drm-round-$$，Ctrl+C 只退出日志跟踪、不影响轮）"
    else
        setsid nohup "$0" >>"$LOGD/desk-takeover.log" 2>&1 </dev/null &
        CHILD=$!
    fi
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
# 每轮的实验开关放这儿（/run 是 tmpfs，重启即回默认，不会偷偷留着上轮的实验设定）。
# 里面可以写 BT_BRIDGE=1 之类的开关，这样从桌面快捷方式进轮也能带上实验设定。
[ -f /run/drm-round.conf ] && . /run/drm-round.conf
PREFIX=22
GW=172.16.30.1

# 设备地址一律交给 scripts/adb-pick.sh：本机/回环优先，且每个候选都要 getprop 真的回话。
# 曾经的事故（10-01 19:47）：行序第一个是**换网后已死的无线地址**，交还命令全发进去，
# 安卓没被拉回来 = 黑屏强启。
. "$DIR/scripts/adb-pick.sh"
DEV=$(pick_adb_dev_with_endpoints 8)
# 本机通道（emulator-5554 一类）没有时，再试配置里的无线 adb 地址。
# ⚠ 只在**进入接管**这一侧加：交还链（desk-stop）刻意不依赖这里——交还时 adb 不通也必须继续往下走，
#    中止交还等于把用户锁在黑屏里。地址写在哪：/etc/drm-takeover.conf 的 ADB_ENDPOINTS。
if [ -z "$DEV" ] && [ -n "${ADB_ENDPOINTS:-}" ]; then
    for _ep in $ADB_ENDPOINTS; do
        adb connect "$_ep" >/dev/null 2>&1
        if timeout 10 adb -s "$_ep" shell getprop ro.build.version.sdk >/dev/null 2>&1; then
            DEV="$_ep"
            echo "ADB-BRIDGE 本机通道不可用，已改用无线地址 $_ep（端口每次重连会变，失效后更新 ADB_ENDPOINTS）"
            break
        fi
    done
fi
if [ -z "$DEV" ]; then
    if [ -z "${ADB_ENDPOINTS:-}" ]; then
        echo "NO-ADB-DEVICE 原因之一：/etc/drm-takeover.conf 里没有 ADB_ENDPOINTS，无线兜底根本没配（只试了本机通道）"
    fi
    # 取证输出：把原表贴进日志（unauthorized / offline / 空表是三种不同处置，不看表分辨不了）
    echo "adb devices 原表："
    timeout 12 adb devices -l 2>&1 | sed 's/^/    /'
    echo "NO-ADB-DEVICE"; exit 1
fi
run() {
    # 同 desk-stop：安卓侧 adb 调用一律限时，卡死=黑屏（09-24 16:52 轮实测 wake_unlock
    # 那一次 adb 调用永久阻塞，把回还流程钉死在半路）。超时必须进日志。
    local out rc
    out=$(timeout 12 adb -s "$DEV" shell "su -c '$1'" 2>&1); rc=$?
    [ $rc -eq 124 ] && echo "RUN-TIMEOUT(12s): $1"
    printf '%s\n' "$out"
    return $rc
}
# 蓝牙桥的进程匹配：一律按 **comm** 匹配（`pgrep bthci-bridge`，不带 -f 也不带 -x）。
# 两个方向都踩过坑（09-30 灰度 bthci-bridge-v2 时全部现形）：
#   · `-x bthci-bridge` 精确匹配 → 改名的桥全体失配：交还/回滚杀不掉它（HAL 客户端位不还安卓）、
#     开局单实例判据看不出已有桥（会再起一个 = 两个 HAL 客户端，正是 §63 那个卡死机制）、
#     desk-stop 的 BT-HANDOVER 判据查不到残留 → 明明活着却报 OK。
#   · `-f` 按 cmdline 匹配 → 更糟：`su -c` 的包装 sh 的 cmdline 里带着桥的路径，会自匹配
#     （实测 6 个"命中"里 5 个是壳），既误判"已有桥"从而不启动，也可能当场杀死自己的壳。
# 桥名截断到 15 字符（Linux comm 上限），所以灰度命名别超过 bthci-bridge-vNNN。
bridge_pids() { run "pgrep bthci-bridge" | tr -d '\r' | grep -E '^[0-9]+$'; }
bridge_kill() {
    local pids
    pids=$(bridge_pids | tr '\n' ' ')
    [ -n "${pids// /}" ] || return 0
    run "kill $pids"
    echo "BT-BRIDGE KILL $(date +%T): pids=${pids}"
}
# supplicant 收尾先优雅退出、超时才 -9（机制上站得住：cfg80211 的 scheduled-scan `Match`
# 只有它自己退出时才注销，被 SIGKILL 就没人清）。
# **但别把它当"第二轮 WiFi 炸"的解药** —— 历史日志里可比的是"自拉 supplicant + WIFI-ASSOC 探针
# 都存在"之后的 23 轮（16 OK / 7 失败）：7 个失败轮里 **4 个 Match 和 flags(UP) 两种签名都没有**，
# Match 只覆盖 2 轮（09-24 15:20、09-25 09:41），flags(UP) 覆盖 2 轮（09:41、10:20）。
# ⇒ 这是"少一个已知错误来源"的卫生修复，主因还没定（明细表见工作总结 5.33）。
stop_supplicant() {
    # 没进程就立刻返回：本机 `systemctl stop wpa_supplicant.service`（unit 不存在也一样）
    # 实测要 7.2s，而 kill_linux_stack / rollback 一条路径上可能进来好几次。
    pgrep -x wpa_supplicant >/dev/null || { rm -f /run/desk-wpa.pid; return 0; }
    # 自拉 nohup 版和 systemd 实例一起按名字处理；先 TERM，超时才 -9（原因见函数头注）
    pkill -TERM -x wpa_supplicant 2>/dev/null   # systemd 管的实例同样吃这个 TERM
    for i in 1 2 3 4 5 6; do
        pgrep -x wpa_supplicant >/dev/null || break
        sleep 1
    done
    if pgrep -x wpa_supplicant >/dev/null; then
        echo "WPA-STOP 优雅退出超时，补 -9（下一轮 WiFi 可能残留 Match，需 WIFI-PRECLEAR 兜）"
        pkill -9 -x wpa_supplicant 2>/dev/null
        sleep 1
    fi
    # 杀完又冒出来 = systemd 按 unit 复活了它，只有这种才付 systemctl 那 7s
    pgrep -x wpa_supplicant >/dev/null && systemctl stop wpa_supplicant.service 2>/dev/null
    rm -f /run/desk-wpa.pid
}
kill_linux_stack() {
    # ---- ① anland 会话整体干净关闭（10-02 晚定稿，§12.39 三次事故合流的结论）----
    # anland 跑在 plasma-* systemd 用户单元里。今天三轮实测把两条半杀路全部证死：
    #   a) 只 pkill 进程：单元把 kwin/kded6/plasmashell/xembedsniproxy 逐个拉回来，
    #      与轮内自拉组件在共享总线打架（幽灵抢 :0、应用全打不开、usb-manager 一点就黑）；
    #   b) 只 mask kwin：kwin 不复活了，但其余单元照拉 ⇒ 半死的 plasma 会话继续捣乱（17:22 轮）。
    # 而"整会话 systemctl stop"在 16:41 黑屏的唯一原因 = 脚本树仍会话 cgroup 里被 logind
    # 连坐收割——这个障碍已被本脚本自脱钩的 system 级 scope（/system.slice，2d836c8）解掉。
    # ⇒ 现在整会话干净 stop 是安全且唯一正确的形态：kwin 单元 Restart=no，干净 stop 不触发
    #    重启 ⇒ 幽灵不存在；其它单元一起走 ⇒ 无半杀水蛇；anland 下次由 desk-stop/手动
    #    startanland-kde.sh 整体拉起（startplasma 重新 start 目标，天然干净）。
    if runuser -u "$DRM_USER" -- env XDG_RUNTIME_DIR=$DRM_RT \
            DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$DRM_UID/bus \
            systemctl --user stop plasma-workspace-wayland.target plasma-core.target 2>/dev/null; then
        echo "PLASMA-SESSION-STOPPED anland 会话已整体干净关闭（scope 已保脚本不死）$(date +%T)"
    else
        echo "PLASMA-SESSION-STOP-SKIP $(date +%T): 没有活动的 plasma 用户单元（anland 未以 systemd 会话形态运行）"
    fi
    # v2: 补全实际 cmdline 模式(v1 的 kwinwrap/socket 模式杀不掉真 kwin)，见 desk-stop.sh 头注
    pkill -9 -f "kwinwrap --out" 2>/dev/null
    pkill -9 -f "socket=taketest" 2>/dev/null
    pkill -9 -f "kwin_wayland_wrapper" 2>/dev/null
    pkill -9 -f "kwin_wayland --" 2>/dev/null
    # Xwayland 是 kwin 的子进程，kwin 被 -9 时不一定跟退；残留会占住 display 号，
    # 让下一轮 kwin --xwayland 挑到别的号或起不来（09-24 接入 XWayland 时同步加）
    pkill -9 -x Xwayland 2>/dev/null
    # Xwayland 是 kwin 的子进程；kwin 被 -9 时它不一定跟着退，残留会占着 /tmp/.X11-unix
    # 的 display 号，让下一轮 kwin --xwayland 挑到别的号或直接失败
    pkill -9 -x Xwayland 2>/dev/null
    # 会话里注入的是写死的 DISPLAY=:0，所以必须保证 :0 真的空出来：anland 遗留的
    # /tmp/.X11-unix/X0 是**没人 listen 的死 socket**，Xwayland bind 它会 EADDRINUSE
    # 而退到 :1，那样注入的 :0 就成了错的。上面已经 Xwayland 全杀，这里的 socket 文件
    # 一律是垃圾（整个容器里只有 anland/DRM 两套 kwin 会造 X socket）。
    rm -f /tmp/.X11-unix/X* /tmp/.X11-lock /tmp/.X*-lock 2>/dev/null
    pkill -9 -f "startplasma-wayland" 2>/dev/null
    pkill -9 -f "plasmashell" 2>/dev/null
    pkill -9 -f "kactivitymanagerd" 2>/dev/null
    pkill -9 -f "org_kde_powerdevil" 2>/dev/null
    pkill -9 -f "plasma-keyboard" 2>/dev/null
    pkill -x fcitx5 2>/dev/null
    pkill -x onboard 2>/dev/null
    pkill -9 -f "dmesg-harvester.sh" 2>/dev/null
    pkill -f "nm-drm.conf" 2>/dev/null
    pkill -x NetworkManager 2>/dev/null
    # 原来这行是 `pkill -f 'wpa_supplicant.*desk-wifi'`：按命令行匹配既杀不到自拉的 -u 版，
    # 又会把"命令行里提到这串字"的调用方 shell 一起杀（09-25 实测 rc=143）。
    # supplicant 一律交给下面的 stop_supplicant（按名字、TERM 优先）。
    stop_supplicant   # systemd 侧 + 自拉 nohup 版都管；TERM 优先、超时才 -9（见函数注释）
    pkill -x dhcpcd 2>/dev/null
    pkill -f "xdg-desktop-portal" 2>/dev/null
    pkill -f "aa-feeder.sh" 2>/dev/null     # A 路容器喂流器（安卓侧 argsloop 由 rollback/desk-stop 各自 run pkill）
    pkill -f "bt-keepalive[.]sh" 2>/dev/null  # 上一轮残留的蓝牙看门狗（它会在下一轮配置生效前乱拉桥）
    # ---- ② 清 display_daemon 的重拉（10-02 深夜）----
    # 宿主 display_daemon 在 anland 死后 ~2s 整体重拉 anland（15:35/16:18/17:35 三轮实锤，
    # 每轮恰一次）。重拉会话的 kded6/kglobalacceld 会占走 org.kde.kded6/org.kde.kglobalaccel
    # 总线名 ⇒ 轮内音量/快捷键链路被污染（AUDIOKEY-RETRY FAIL 的真因）。等它拉完（5s）再清一次。
    sleep 5
    pkill -9 -f "startplasma-wayland" 2>/dev/null
    pkill -9 -f "kwin_wayland_wrapper" 2>/dev/null
    pkill -9 -f "kwin_wayland --wayland-fd" 2>/dev/null
    pkill -9 -x Xwayland 2>/dev/null
    pkill -9 -x kded6 2>/dev/null
    pkill -9 -f plasmashell 2>/dev/null
    pkill -9 -x fcitx5 2>/dev/null
    rm -f /tmp/.X11-unix/X* /tmp/.X11-lock /tmp/.X*-lock 2>/dev/null
    sleep 2
    if pgrep -f "startplasma-wayland" >/dev/null 2>&1; then
        pkill -9 -f "startplasma-wayland" 2>/dev/null
        pkill -9 -f "kwin_wayland_wrapper" 2>/dev/null
        pkill -9 -f "kwin_wayland --wayland-fd" 2>/dev/null
        pkill -9 -x Xwayland 2>/dev/null
        echo "GHOST-RE-RESPAWN $(date +%T): display_daemon 又拉了一轮，已再清（此行反复出现 ⇒ daemon 循环重拉，需回头改方案）"
    else
        echo "GHOST-CLEAN $(date +%T): display_daemon 的重拉已清，总线名归还轮内组件"
    fi
    sleep 1
    fuser -k /dev/dri/card0 2>/dev/null
    rm -f $DIR/takeover.ok
}

rollback() {
    echo "ROLLBACK: $* ($(date +%T))"
    kill_linux_stack
    # 交还安卓前必须放掉蓝牙桥：桥活着 = 我们和安卓的蓝牙栈同时持有 HAL 客户端位，
    # 抢同一颗 combo 芯片的电源协调（09-25 两轮把 WiFi 打进 recovery 死循环的直接嫌疑）。
    # rollback 不走 desk-stop，所以这里也得自己杀（见工作总结 5.30）。
    # 顺序要紧：先停看门狗，再杀桥 —— 反过来桥被杀的那一瞬间看门狗会把它当"桥没在跑"重新拉起。
    pkill -f "bt-keepalive[.]sh" 2>/dev/null
    bridge_kill
    # 交还/回滚路径杀完必须确认杀干净（历史坑见上：漏网 = 安卓 framework 拿不到 HAL）
    echo "BT-BRIDGE-AFTER-ROLLBACK left=$(bridge_pids | tr '\n' ' ') $(date +%T)"
    # 总线策略也不能泄漏给轮外（rollback 不走 desk-stop，得自己撤）
    if [ -f /etc/dbus-1/system.d/61-bluez-drm-lock.conf ]; then
        rm -f /etc/dbus-1/system.d/61-bluez-drm-lock.conf
        dbus-send --system --dest=org.freedesktop.DBus /org/freedesktop/DBus \
            org.freedesktop.DBus.ReloadConfig >/dev/null 2>&1
        echo "BT-LOCK REMOVED（rollback 路径）$(date +%T)"
    fi
    # A 路音频：安卓侧常驻 sink（进程名 argsloop）与容器侧 feeder 都要放掉，
    # 否则交还后 audioserver 想接管 HAL 会被我们占着的 stream/patch 挡住（端口 63/deep_buffer 被占）。
    run "pkill -x argsloop" 2>/dev/null
    pkill -f "aa-feeder.sh" 2>/dev/null
    # pc-keyd 同理：rollback 不走 desk-stop，本轮起的实例要自己清（uinput 键盘会让安卓发键盘通知，09-27）。
    pkill -f "pc-keyd.py" 2>/dev/null
    # kwinrc 的 AllowTearing（2d 段写入）同样不能泄漏给 anland：rollback 必须自己删。
    kwriteconfig6 --file "$DRM_HOME/.config/kwinrc" --group Compositing --key AllowTearing --delete 2>/dev/null
    chown "$DRM_USER:$DRM_USER" "$DRM_HOME/.config/kwinrc" 2>/dev/null
    # 轮内 fcitx5 实例清理：交还后 anland 会话会自拉自己的 fcitx5（座位同为 fcitx5，
    # 09-29 统一），这里只杀掉本轮起的那个，不动 kwinrc（两模式同值，无需恢复）。
    pkill -x fcitx5 2>/dev/null
    # GPUFLOOR 还原（1c 段）：共享内核，rollback 不还原 = 钉死的频率泄漏给 anland/安卓。
    # 还原值在 /run/desk-gpufreq.orig；文件丢失时按 takeover 日志里的 GPUFLOOR ORIG 行手工还原。
    if [ -f /run/desk-gpufreq.orig ]; then
        read -r GM GO < /run/desk-gpufreq.orig
        [ -z "$GO" ] && { GO="$GM"; GM=444; }   # 兼容旧的单值格式
        case "$GO" in
        *[!0-9]*|"") rm -f /run/desk-gpufreq.orig ;;
        *) case "$GM" in *[!0-9]*|"") GM=444 ;; esac
           # 先 chmod 解锁再写：vendor 温控/perfd 可能已把 mode 改回 0444（1c 段写完会复原）
           GOUT=$(run "chmod 0644 /sys/class/kgsl/kgsl-3d0/min_pwrlevel; echo $GO > /sys/class/kgsl/kgsl-3d0/min_pwrlevel; chmod $GM /sys/class/kgsl/kgsl-3d0/min_pwrlevel; cat /sys/class/kgsl/kgsl-3d0/min_pwrlevel" | tr -d '\r' | awk 'END{print}')
           rm -f /run/desk-gpufreq.orig
           if [ "$GOUT" = "$GO" ]; then
               echo "GPUFLOOR-RESTORE OK min_pwrlevel=$GO (mode->$GM)"
           else
               echo "GPUFLOOR-RESTORE FAIL 回读=$GOUT 预期=$GO ⇒ 频率可能还钉着，手工：chmod 0644 /sys/class/kgsl/kgsl-3d0/min_pwrlevel; echo $GO > 同路径; chmod $GM 同路径"
           fi ;;
        esac
    fi
    # PERFMAX 还原（1d 段）：先让重申循环退出（否则 restore 完立刻被写回顶档），再按记录还原 + 回读自证。
    if [ -n "$(run "test -s /data/local/tmp/perfmax.orig && echo HASREC")" ]; then
        run "sh /data/local/tmp/perfmax.sh stop" >/dev/null 2>&1
        sleep 3
        run "sh /data/local/tmp/perfmax.sh restore" | tail -n 6
    fi
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
# xtrace 会把 CUR_PSK 的赋值行和后面 nmcli connect 展开后的命令行原样写进
# logs/desk-takeover.log（09-24 12:21 轮实锤：password 明文在档）→ PSK 读写段静音
set +x
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
set -x

# ---- 1) DRM 节点 + udev 合成记录（与 drm-takeover.sh 同源） ----
mkdir -p /dev/dri /dev/input
[ -c /dev/dri/card0 ] || mknod /dev/dri/card0 c 226 0
# GPU 计算节点的兜底（**真因不在这儿**，见 5.34①：kwinwrap 切 uid 时丢了补充组，
# 已经用 initgroups 修掉；节点本来就存在，是 `crw-rw---- root:droidspaces-gpu(786)`）。
# 这里仍保留"缺则建 + chmod"，因为它兜的是另一类情况：容器重启后 /dev 是合成的，
# 节点可能压根没被 udev 建出来（card0/renderD128 都出现过这种轮）。
# chmod 是放宽，不是主修；主修在 src/kwinwrap.c 的 initgroups。
mk_dri_node() {  # $1=sysfs 类下的相对路径  $2=落地的 /dev 路径
    local d mj mn
    d="/sys/class/$1"
    [ -e "$d/dev" ] || return 1
    IFS=: read -r mj mn < "$d/dev"
    [ -n "$mj" ] && [ -n "$mn" ] || return 1
    if [ -c "$2" ]; then echo "GPU-NODE 已有 $2 = $mj:$mn"; return 0; fi
    mknod "$2" c "$mj" "$mn" 2>/dev/null || { echo "GPU-NODE mknod 失败 $2"; return 1; }
    # 只对**这里新建出来的**节点生效：mknod 出来是 0600 root:root，桌面用户（uid 1000）
    # 根本用不了 ⇒ 必须放宽，做法与 card0 那行 `chmod 666 /dev/dri/card0` 一致。
    # 注意：**已存在的节点一个字节都不碰**（上面 return 0）—— udev/ueventd 建的
    # renderD128 是 `crw-rw---- root:droidspaces-gpu(786)`，那是系统的策略，不该由轮来改。
    # 09-25 我曾给已存在的节点也 chmod 666，那是多余动作且白开权限，已去掉。
    chgrp droidspaces-gpu "$2" 2>/dev/null; chmod 660 "$2" 2>/dev/null
    echo "GPU-NODE 新建 $2 = $mj:$mn"
}
# renderD128 在 drm 类下（可能不止一个），kgsl-3d0 在 kgsl 类下
for r in /sys/class/drm/renderD*; do
    [ -e "$r/dev" ] || continue
    mk_dri_node "drm/$(basename "$r")" "/dev/dri/$(basename "$r")"
done
mk_dri_node "kgsl/kgsl-3d0" "/dev/kgsl-3d0"
# NM 靠 rfkill netlink 控制 WiFi 射频；容器重启后 /dev 重建，缺这节点=扫不到任何热点（09-23 实锤）
[ -c /dev/rfkill ] || mknod /dev/rfkill c 10 242
chmod 666 /dev/rfkill 2>/dev/null
# pc-keyd v2 的 uinput 兜底路径要这个节点（内核 CONFIG_INPUT_UINPUT=y，只差节点）。
# 09-27 v2 主通道改 XTEST/EIS（不再默认创建 uinput 设备 → 安卓"物理键盘"通知消失，
# uinput 防滥用红线随之退役）；节点仅为 uinput 兜底保留。
[ -c /dev/uinput ] || mknod /dev/uinput c 10 223
chmod 666 /dev/uinput 2>/dev/null
# pc-keyd v2（组合键守护，droid-pc-keyboard 仓）改为 kwin/Xwayland 就绪后以会话用户启动
# （见 DESKTOP-UP 之后的 PC2-UP 段）：XTEST 注入无需 root，且 DRM Xwayland 拒绝 root 的
# X 连接（13:41 轮实测）。
# power-state-sync：小米 BSP 电流符号与内核 ABI 相反 → upower 永远判放电。
# bind-mount 取反 current_now + 周期 kick（脚本自带幂等挂载判断；跨会话常驻，
# desk-stop 不杀它，anland 托盘顺带受益）。
[ -f /usr/local/bin/power-state-sync.py ] && { pgrep -f "power-state-sync" >/dev/null || nohup python3 /usr/local/bin/power-state-sync.py > /tmp/power-sync.log 2>&1 & }
chmod 666 /dev/dri/card0 2>/dev/null
# 触摸屏的 eventN 在**同一开机的第二轮**会被活的 udevd 冷插成别的号（09-25 实测：第二轮
# "2.4G 鼠标能用、触屏挂"）⇒ 节点号/major:minor 一律按设备名现查，不再硬编码 event11(13:75)。
find_touch() {
    local e
    for e in /sys/class/input/event*; do
        [ -e "$e/device/name" ] || continue
        grep -qi "NVTCapacitiveTouchScreen" "$e/device/name" 2>/dev/null && { printf '%s\n' "$e"; return 0; }
    done
    printf '%s\n' /sys/class/input/event11   # 兜底：sysfs 名字没读到时退回老节点
}
TS=$(find_touch)
TSNODE=$(basename "$TS")
TSMAJ=""; TSMIN=""
if [ -e "$TS/dev" ]; then
    TSMAJ=$(cut -d: -f1 "$TS/dev"); TSMIN=$(cut -d: -f2 "$TS/dev")
    [ -c "/dev/input/$TSNODE" ] || mknod "/dev/input/$TSNODE" c "$TSMAJ" "$TSMIN"
else
    # sysfs 里没有它 ⇒ 宁可不建：按老 13:75 硬建一个节点只会造成"假触摸屏"（节点名对、
    # 号段却是别的设备），libinput 打开后什么都收不到，比明着没有更难查。
    echo "TOUCH-SYSFS FAIL: $TS 无 dev ⇒ 本轮触摸屏不可用（查 NVT 驱动是否 probe）"
fi
# BLE 外设（鼠标/键盘/手柄）走 BlueZ HOGP→内核 uhid 才会长出 /dev/input/eventN；
# 安卓侧有 /dev/uhid(10:239, CONFIG_UHID=y)，但容器这份 /dev 没有节点 ⇒ 设置里"连上了"
# 却完全没有指针（09-25 实测）。
[ -c /dev/uhid ] || mknod /dev/uhid c 10 239
chmod 666 /dev/uhid 2>/dev/null
# ---- 1b) 输入热插拔：起裸 udevd（不碰单元）+ 把 net 规则冻死 ----
# 症状与已证事实（09-25）：libinput 的热插拔监听走 libudev 的 "udev" 作用域，要连
# `/run/udev/control`；那个 socket 不在 ⇒ kwin 整轮没有输入热插拔（"蓝牙鼠标连上但没指针"、
# 新插的 2.4G 鼠标也不动，而触摸屏可用因为它在 kwin 之前就有节点）。
# 实测（09-25 11:0x，anland 里）：`nohup /usr/lib/systemd/systemd-udevd` 这种裸实例**会**建
# /run/udev/control（之前我说"裸实例不建 socket"是错的，那次是单元 skipped 且没等够时间）。
# 所以热插拔不需要动单元。改名风险另有屏蔽：/etc/udev/rules.d/80-net-setup-link.rules → /dev/null，
# 其余带 NAME= 的 net 规则只匹配 idrac/ibmimm 那种 USB 网卡，碰不到 wlan0。
# （试过 `OPTIONS+="last_rule"` 冻结 net，本机 udev 直接报 Invalid value 忽略 ⇒ 无效配置，删掉。）
# 教训保留（别再犯）：用 zz-* 命名的 drop-in 清 Droid Spaces 的 ExecCondition 再
# `systemctl restart systemd-udevd` —— 那一轮 WiFi 炸 + 返回链卡死（见 5.31；
# 顺带记着 99-drm-* 会排在 99-hwaccess-* 前面、空赋值会被覆盖）。
ln -sf /dev/null /etc/udev/rules.d/80-net-setup-link.rules
# **绝不在接管轮里 restart 真 udevd 单元**（09-25 隔离实验的结论）：
#   UDEV_FORCE=0 的那轮 → WIFI-ASSOC OK / NET-TAKEOVER OK，触屏与鼠标启动前设备都在；
#   UDEV_FORCE=1 的那轮 → WiFi 炸 + 「返回安卓」卡死（只能强启）。
# 注意（用户 09-25 纠正，别再拿 anland 当对照）：**anland 走的是安卓的网络**（容器里是转发口，
# wlan0 归安卓 netd），而接管轮里是**容器的 NM 直接持有 wlan0（共享 netns）**——两场景不可比，
# 所以"anland 也有活 udevd 却没事"证明不了 udevd 无罪。
# 但 09-24 那些 WiFi 正常的好轮**本来就在跑裸 udevd**（WiFi 段的兜底），所以本轮沿用同一方式：
# socket 不存在时只起裸实例，不碰单元、不碰 ExecCondition。
if [ ! -S /run/udev/control ]; then
    pgrep -x systemd-udevd >/dev/null || { nohup /usr/lib/systemd/systemd-udevd >/dev/null 2>&1 & sleep 3; }
fi
if [ -S /run/udev/control ]; then
    echo "UDEV-HOTPLUG OK $(date +%T)（裸 udevd 在跑，未碰单元；改名规则已屏蔽）"
else
    echo "UDEV-HOTPLUG OFF $(date +%T)：裸 udevd 没建出 /run/udev/control ⇒ 本轮新插设备要重启 kwin 才认（触屏不受影响）"
fi
# 输入设备节点常驻同步器（详见 scripts/input-node-sync.sh 头注）：**必须在 kwin 之前**起，
# 因为 libinput 只在启动时枚举一次 /dev/input。
# 用 setsid+nohup：绝不能挂在我的调用链上（09-25 黑屏事故的直接教训）。
nohup setsid bash $DIR/scripts/input-node-sync.sh > $LOGD/input-node-sync.log 2>&1 &
chmod 666 "/dev/input/$TSNODE" 2>/dev/null
# 自证探针（09-25 教训：整轮都是"权限不对但没人报错"）：以**桌面用户身份**试读触摸屏。
# 读不到就等于触摸屏 + 一切鼠标全失效，必须当场喊出来，而不是等用户报"用不了"。
if runuser -u "$DRM_USER" -- test -r "/dev/input/$TSNODE" 2>/dev/null; then
    echo "INPUT-PERM OK $(date +%T)：uid 1000 可读 /dev/input/$TSNODE"
else
    echo "INPUT-PERM FAIL $(date +%T)：uid 1000 读不了 /dev/input/$TSNODE ⇒ 触摸屏与所有鼠标都会失效"
    echo "   多半是 udev 把节点规范成 root:input 0660 而容器无 logind ⇒ 没人下发 uaccess ACL；"
    echo "   解法＝scripts/input-node-sync.sh 里那条 MODE=\"0666\" 规则（已随同步器安装）"
fi
# GPU 同一条纪律：kwin 是 uid 1000 起的，打不开 render 节点就**静默退回软件渲染**
# （llvmpipe），画面照样出，只是花屏/掉帧，最容易被骗成"GPU 驱动炸了"。当场以桌面用户身份验。
GPU_OK=1
for n in /dev/dri/renderD128 /dev/kgsl-3d0; do
    if runuser -u "$DRM_USER" -- test -r "$n" -a -w "$n" 2>/dev/null; then
        echo "GPU-PERM OK $(date +%T)：uid 1000 可读写 $n"
    else
        echo "GPU-PERM FAIL $(date +%T)：uid 1000 读写不了 $n ⇒ kwin 会退软件渲染（花屏/无动效）"
        GPU_OK=0
    fi
done
[ "$GPU_OK" = 1 ] || echo "   解法＝src/kwinwrap.c 的 initgroups（补充组才是真因，见工作总结 5.34①），其次才是上面 mk_dri_node 的兜底"
mkdir -p /run/udev/data
# 原来这三份合成记录**共用一个条件**（c226:0 存在就整块跳过）⇒ 同一开机的第二轮里
# card0 记录还在、触摸屏那份却没重写，而触摸屏节点号这时已经被活的 udevd 冷插成别的
# eventN（09-25 实测第二轮"2.4G 鼠标能用、触屏挂"） ⇒ 拆成各自独立判断。
if ! grep -q DRIVER /run/udev/data/c226:0 2>/dev/null; then
    printf 'Q:100\nE:DEVPATH=/devices/platform/soc/ae00000.qcom,mdss_mdp/drm/card0\nE:MAJOR=226\nE:MINOR=0\nE:SUBSYSTEM=drm\nE:DEVTYPE=drm_minor\nE:DEVNAME=dri/card0\nE:DRIVER=vmwgfx\nH:uaccess\nH:seat\n' > /run/udev/data/c226:0
fi
if ! grep -q DRIVER /run/udev/data/c226:128 2>/dev/null; then
    printf 'Q:101\nE:DEVPATH=/devices/platform/soc/ae00000.qcom,mdss_mdp/drm/renderD128\nE:MAJOR=226\nE:MINOR=128\nE:SUBSYSTEM=drm\nE:DEVTYPE=drm_minor\nE:DEVNAME=dri/renderD128\nE:DRIVER=vmwgfx\nH:uaccess\nH:seat\n' > /run/udev/data/c226:128
fi
# 触摸屏记录：**按设备名找它现在的 major:minor**，不再硬编码 13:75/event11。
if [ -n "$TSMAJ" ] && [ -n "$TSMIN" ]; then
    TSPATH=$(readlink -f "$TS/device"); TSPATH=${TSPATH#/sys}
    chmod 666 "/dev/input/$TSNODE" 2>/dev/null
    printf 'Q:100\nE:DEVPATH=%s\nE:MAJOR=%s\nE:MINOR=%s\nE:SUBSYSTEM=input\nE:DEVNAME=input/%s\nE:ID_INPUT=1\nE:ID_INPUT_TOUCH=1\nE:ID_INPUT_TOUCHSCREEN=1\nE:LIBINPUT_DEVICE_GROUP=11/6/15d9:NVTCapacitiveTouchScreen\nE:LIBINPUT_CALIBRATION_MATRIX=0 1 0 -1 0 1 0 0 1\nH:uaccess\nH:seat\n' \
        "$TSPATH" "$TSMAJ" "$TSMIN" "$TSNODE" > "/run/udev/data/c$TSMAJ:$TSMIN"
    echo "TOUCH-RECORD $TSNODE ($TSMAJ:$TSMIN) 已按设备名重写"
else
    echo "TOUCH-RECORD FAIL: 拿不到触摸屏的 major:minor ⇒ 触摸会失效"
fi
chmod -R a+rX /run/udev

# ---- 1c) GPUFLOOR 实验（默认关；09-28 同轮 A/B 实测钉频只值 ~6-16%、噪声就有 8.7%，
#          见工作总结 §44 ⇒ 不作性能手段，只在测"频率-性能曲线"时显式开：
#          /run/drm-round.conf 写 GPUFLOOR=1，或环境变量 GPUFLOOR=1）----
# 钉 GPU `min_pwrlevel=0`（kgsl pwrlevel 0=最高档），让 GPU 全程驻留顶频。
# 根因（09-28 实测，推翻 42.1 的"必是 SELinux"）：拦路是 **kernfs 自己的 DAC 检查**——
# 同一 SELinux 标签(u:object_r:vendor_sysfs_kgsl)、同一全量 caps(CapEff=000001ffffffffff)，
# 把节点 mode 从 0444 改成 0200 后写入立刻成功、改回 0444 又 EACCES。⇒ 无写位时
# **CAP_DAC_OVERRIDE 对 sysfs 节点不豁免**，与 SELinux 无关，别再查 avc。
# 修法：`chmod 0644` → 写 → 立刻把 mode 复原（值会保持钉住，mode 只影响后续写入）。
# KSU 模块 `drm_gpu_pin`（sepolicy.rule 放行 ksu 写 vendor_sysfs_kgsl）09-28 已装并重启过，
# 但按上面结论它**可能本来就是多余的**（未证伪：证伪要删模块再重启）；留着无害。
# 实测收益：钉 0 后空闲 devfreq/cur_freq 即 1050000000（还原 13 后回落 160MHz）⇒ 旋钮真有效。
# 09-27 实测基线：vkmark 全程 GPU 驻留 342MHz（顶档 1050MHz，DCVS 不升），
# 3.07x 空间 ≈ 群友 anland+Scene 7000→20000 的倍率；devfreq/min_freq 同为 0444，现在已知
# 解锁路径（chmod），但 min_pwrlevel 是 Scene 同款旋钮，继续用它。
# 纪律：①单变量——本轮别再钉 CPU；②共享内核 ⇒ rollback/desk-stop 必须还原（orig 同时落
# /run/desk-gpufreq.orig 与本日志，防 /run 丢失成孤儿钉）；③钉死后 thermal cooling 仍可
# 下压，但 DCVS 的省电偏置被绕过 ⇒ 只作实验勿常驻；④写后必须回读自证（5.27）。
if [ "${GPUFLOOR:-0}" = 1 ] && [ "${PERFMAX:-0}" != 1 ]; then
    GKN=/sys/class/kgsl/kgsl-3d0/min_pwrlevel
    GMIN=$(run "cat $GKN" | tr -d '\r' | awk 'END{print}')
    GMODE=$(run "stat -c %a $GKN" | tr -d '\r' | awk 'END{print}')
    case "$GMIN" in
    *[!0-9]*|"") echo "GPUFLOOR SKIP: min_pwrlevel 读取异常[$GMIN]，宁可不钉" ;;
    *)
        case "$GMODE" in *[!0-9]*|"") GMODE=444 ;; esac
        # 没有还原记录就不许钉：/run 写失败（非 root/被挂 ro）时若继续钉 = 孤儿钉泄漏给 anland
        #（09-28 干跑实锤：orig 写入 permission denied，钉成功了、4g 段因文件不存在直接跳过）。
        if ! echo "$GMODE $GMIN" > /run/desk-gpufreq.orig 2>/dev/null; then
            echo "GPUFLOOR SKIP: 还原记录写不进 /run/desk-gpufreq.orig ⇒ 无记录不钉（防孤儿钉）"
        else
            echo "GPUFLOOR ORIG mode=$GMODE min_pwrlevel=$GMIN（异常中断手工还原：chmod 0644 $GKN; echo $GMIN > $GKN; chmod $GMODE $GKN）"
            run "chmod 0644 $GKN; echo 0 > $GKN; chmod $GMODE $GKN"
            GCHK=$(run "cat $GKN" | tr -d '\r' | awk 'END{print}')
            if [ "$GCHK" = "0" ]; then
                echo "GPUFLOOR OK: min_pwrlevel 已钉 0（GPU 全程驻留最高档，含空闲）"
            else
                echo "GPUFLOOR FAIL: 回读=$GCHK 预期=0（chmod 或写入被拒——拦路是 kernfs DAC 不是 SELinux，别去查 avc）"
            fi
        fi
        ;;
    esac
    unset GKN GMIN GMODE GCHK
fi

# ---- 1d) PERFMAX 实验（默认关；/run/drm-round.conf 写 PERFMAX=1 或环境变量开）----
# 把这台机器 sysfs 能拧的旋钮全拧到顶：CPU 两簇 min=max、GPU（min_pwrlevel=0 + 关 pwrscale/hwcg/ifpc）、
# DDR/LLCC 频率地板。**为什么不是 perflock**：MIUI/QTI 的 perf HAL 对调用方做按包名的白名单校验
# （IMiPerf::getXmlcont 返回的就是那张"包名×场景×PERF_LOCK_ACQUIRE"表），root(uid 0) 发过去
# 一律 EX_SERVICE_SPECIFIC(-8)；而这三个旋钮 sysfs 都能直接拧 ⇒ 不需要 HAL。详见 scripts/perfmax.sh 头与工作总结 §48。
# 代价（务必知道）：CPU 常驻顶频 + 内存地板拉满，实测 die 能到 65~69°C、掉电明显 ⇒ 只作跑分/实验，勿当桌面常驻。
# 与 1c 的 GPUFLOOR 互斥（动同一个 min_pwrlevel，两边的还原记录会打架），同时开时以 PERFMAX 为准。
# 还原：perfmax.sh 自己在安卓侧留记录（无记录不拧），rollback 与 desk-stop 都调 stop+restore 并回读自证。
if [ "${PERFMAX:-0}" = 1 ]; then
    if adb -s "$DEV" push "$DIR/scripts/perfmax.sh" /data/local/tmp/perfmax.sh >/dev/null 2>&1; then
        run "chmod 755 /data/local/tmp/perfmax.sh; rm -f /data/local/tmp/perfmax.stop /data/local/tmp/perfmax.out"
        # 先 pin 一次：它会写记录（写不进就拒绝拧）并打印回读自证，这行日志是本轮分数能不能用的前提
        run "sh /data/local/tmp/perfmax.sh pin" | tail -n 5
        # 再起循环：perf 守护进程会在几秒内把 scaling_max_freq 改回去（09-28 实测 3532800→2745600），
        # 单次写必被覆盖。循环自带 60 分钟上限，忘了也不会一直满频。
        run "setsid nohup sh /data/local/tmp/perfmax.sh loop >>/data/local/tmp/perfmax.out 2>&1 &"
        sleep 3
        run "tail -n 3 /data/local/tmp/perfmax.out"
    else
        echo "PERFMAX SKIP: push scripts/perfmax.sh 失败"
    fi
fi

# ---- 2) 悬停保护 + 放倒安卓框架（网会掉 ~10-40s，属预期） ----
run "setprop ctl.stop system_suspend"
run "echo qoderdbg > /sys/power/wake_lock"
# 这里**不放** `svc bluetooth enable`（09-24 加了又撤）：实测两台次都在"enable→几秒后 stop"
# 之后 2–3 分钟内整机挂死、console 静默 ~86s 后看门狗复位（mtdoops reason=7），
# 机制上讲得通：enable 会拉起 com.android.bluetooth + btpower/cnss 的上电序列，
# 序列没走完就把 framework `stop` 掉 = 把协调者打断在半程（正是红线那类 combo 芯片事故）。
# 而且根本不需要它：本机开机安卓自己就把蓝牙开着（用户实测"重启后自动开，我无法控制"），
# 桥在冷 HAL 上（fd=0）自己 initialize 就能把传输开起来（09-24 23:05 实测）。
run "stop"
# stop 不动 class hal！composer HAL 活着就还持有 DRM master（SET_MASTER EBUSY），
# kwin 拿不到屏 → 黑屏（09-21 的坑，drm-takeover 同款处理）
run "setprop ctl.stop vendor.qti.hardware.display.composer"
sleep 5
# 阶段边界判据（09-30 给 drm-tui 的进度视图用）：这一段之后安卓显示栈整体下线、
# 网会掉 10~40s 属预期；用户在这一段看到"没画面"是**正常过程**，不是失败。
echo "ANDROID-STOP 安卓显示栈已放倒 $(date +%T)（接下来 10~40s 内网络会掉、屏幕暂时无画面，均属预期）"

# ---- 2b) 音频桥开关（09-26 起默认开 → **09-30 改默认关**；要开用 AUDIO_BRIDGE=1）----
# 为什么关：A 路 = 停掉 audioserver、我们的 argsloop SINK 直连 vendor AIDL HAL 独占喇叭输出端口
# （deep_buffer/speaker + setAudioPatch）。蓝牙音频（A2DP）走安卓自己的 audioserver → 蓝牙音频
# 轨道，两者抢同一套输出路由：A 路在跑时蓝牙声音出不来/被抢回喇叭（09-30 用户实测到冲突）。
# 先默认关掉 A 路让蓝牙可用；**两条音频路共存的正确做法仍是待办**（工作总结 §58 末尾待办 ⑤）。
# 临时打开：echo 'AUDIO_BRIDGE=1' > /run/drm-round.conf   （/run 是 tmpfs，重启即回默认）
# 两条路线，用 AUDIO_ROUTE 选（默认 a）：
#   · a = **A 路（已跑通并出声，见 droid-audio-bridge《直连音频HAL方案》§31~§34）**：
#         audioserver 保持停（上面 `stop` 已把 class core 停了），我们的进程直连 vendor AIDL HAL：
#         自建 deep_buffer/speaker portConfig + setAudioPatch + openOutputStream + FMQ 喂 PCM → 喇叭。
#         终点 = /data/local/tmp/halsink.sh（常驻 argsloop SINK，监听 127.0.0.1:44777）；
#         容器侧 aa-feeder.sh（抓 PipeWire monitor 的 s16 PCM）推到那个口，在 §桌面起来后再拉起（见后）。
#   · b = 旧 B′ 路：把 audioserver 拉回来给 AAudio（aa-bridge 路线；§38 那条"轮内冷启 audioserver
#         可能卡在等 system_server"未定案，故仅作回退选项保留）。
# **红线**：音频非关键路径，任何一步失败都只 echo + || true，绝不 rollback（不能因为没声音把桌面搭进去）。
if [ "${AUDIO_BRIDGE:-0}" = 1 ]; then
  AUDIO_ROUTE=${AUDIO_ROUTE:-a}
  if [ "$AUDIO_ROUTE" = b ]; then
    run "setprop ctl.start system_suspend; sleep 2; setprop ctl.start audioserver"
    sleep 6
    echo "AUDIO-BRIDGE(B) 拉起后状态: $(run "getprop init.svc.system_suspend; getprop init.svc.audioserver" 2>/dev/null | tr '\n' ' ')"
  else
    # A 路：确认 audioserver 是死的（HAL 才归我们），vendor audio HAL 活着。
    run "setprop ctl.stop audioserver" >/dev/null 2>&1
    ASVC=$(run "getprop init.svc.audioserver" 2>/dev/null | tr -d '\r')
    HAL=$(run "getprop init.svc.vendor.audio-hal-aidl" 2>/dev/null | tr -d '\r')
    echo "AUDIO-BRIDGE(A) 前置: audioserver=$ASVC audioHAL=$HAL $(date +%T)"
    # 直接尝试起安卓侧常驻 sink（halsink.sh 自带缺文件自检并退出 3）；起完用 pgrep 复验。
    # 不预判文件是否存在：run 对空输出也补换行，老写法 `MISS=$(run … | tr)` 恒得一个空格→恒误判 SKIP。
    run 'pgrep -x argsloop >/dev/null || (nohup sh /data/local/tmp/halsink.sh 44777 >>/data/local/tmp/hal-sink.log 2>&1 </dev/null &)' >/dev/null 2>&1
    sleep 2
    if [ -n "$(run 'pgrep -x argsloop' 2>/dev/null | tr -dc '0-9')" ]; then
      echo "AUDIO-BRIDGE(A) 安卓 sink 已起（监听 :44777，日志 /data/local/tmp/hal-sink.log）$(date +%T)"
    else
      echo "AUDIO-BRIDGE(A) sink 没起来：查 /data/local/tmp/hal-sink.log（多半缺 argsloop/halsink.sh/模板，先 push droid-audio-bridge 产物+模板）"
    fi
  fi
fi


# ---- IM：复刻 09-29 09:05~09:20 实测成功态（关键在**顺序**，不是最终配置）----
# 用户实测“弹窗+Ctrl+Space 切拼音”那段能兼得,拼出配方：
#  ① 起跑座位=**plasma-keyboard**：kwin 登记并自拉它 → 弹出机制全程可用（弹窗跟着
#     “键盘 app 登记”走,与守护无关）；
#  ② 桌面起来**之后**再补拉带 WAYLAND_DISPLAY 的 fcitx5（见文末 FCITX5-BYST 段）：
#     imv2 先到先得,plasma-keyboard 已占座位 → fcitx5 只能当旁观者（不抢面板名额）,
#     但它的 XIM 服务器/dbus 前端全功能 → X11 应用（zcode/星火/trae）的 Ctrl+Space
#     经应用 XIM 转发给 fcitx5,实测可用（09:21 用户原话“x11 应用 Ctrl+space 已可用”）；
#  ③ 应用侧仍剥 QT/GTK_IM_MODULE（保住 text-input 上报→弹窗）,XMODIFIERS=@im=fcitx5
#     保留（X11 preedit/热键通道）。SDL/GLFW 剥。
#  ④（文末 BYST 段执行）守护就绪后把 kwinrc 改回 fcitx5 并 `KWin reconfigure` **热换
#     IM 座位**:kwin 的面板注册(virtualkeyboard 插件)只在启动时读 InputMethod,已钉死
#     plasma-keyboard,reconfigure 不动它 → 座位=fcitx5(全桌含 Wayland 的键流/热键/组词)
#     + 面板=plasma-keyboard(弹窗)= 09:05~09:20 手测态的完整复刻(09:17 实证:热换后
#     kwin 依旧重拉 plasma-keyboard)。
# 失败态对照（防再踩）：起跑就把 InputMethod=fcitx5 → 面板注册同被占、弹不出
#   =12:56/14:16 轮；守护剥 WAYLAND_DISPLAY 且不做④热换 → 热键半死=10:0x 轮。
sed -i 's/^\(enabledLocales=\).*/\1en_US,zh_CN/' "$DRM_HOME/.config/plasmakeyboardrc" 2>/dev/null \
    || printf '[General]\nenabledLocales=en_US,zh_CN\n' > "$DRM_HOME/.config/plasmakeyboardrc"
chown "$DRM_USER:$DRM_USER" "$DRM_HOME/.config/plasmakeyboardrc" 2>/dev/null
# 必须用 kwriteconfig6 而不是 sed：sed 只能改**已存在**的行，全新容器的 kwinrc 里根本没有这个键，
# 于是"看起来执行了、实际永远不生效"（10-01 新容器虚拟键盘没出现的直接原因）。
kwriteconfig6 --file "$DRM_HOME/.config/kwinrc" --group Wayland --key VirtualKeyboardEnabled true 2>/dev/null \
    || echo "VK-CONFIG FAIL 写不进 kwinrc，本轮虚拟键盘不会弹出"
KIM="$DRM_HOME/.config/kwinrc"
if grep -q '^InputMethod\[' "$KIM" 2>/dev/null; then
    sed -i 's|^InputMethod\[.*|InputMethod[$e]=/usr/share/applications/org.kde.plasma.keyboard.desktop|' "$KIM"
else
    printf '[Wayland]\nInputMethod[$e]=/usr/share/applications/org.kde.plasma.keyboard.desktop\n' >> "$KIM"
fi
chown "$DRM_USER:$DRM_USER" "$KIM" 2>/dev/null
unset KIM

# ---- 2d) VKMARK-ASYNC 实验（09-27，默认开；VKMARK_ASYNC=0 关）----
# 依据：vkmark 分数=平均 fps，DRM 轮实测 13555≈135.5fps 贴刷新率墙——GPU 不是瓶颈，
# 呈现被 vsync 的 FIFO/mailbox 串行化才是。开 KWin 官方 AllowTearing 后，应用可用
# immediate 呈现（vkmark -p immediate），fps 脱离刷新率、由 GPU 吞吐决定。
# kwinrc 是全局文件（双桌面共享 HOME）：轮内写入、desk-stop 删除；中途异常泄漏到
# anland 的后果=仅当应用主动请求 immediate 且满足直扫条件才可能撕裂，良性可接受。
# kwriteconfig6 以 root 改写会换属主，写完必须 chown 回桌面用户，否则 kwin/anland 都写不了自己的配置。
if [ "${VKMARK_ASYNC:-1}" = 1 ]; then
    KRC="$DRM_HOME/.config/kwinrc"
    kwriteconfig6 --file "$KRC" --group Compositing --key AllowTearing true
    chown "$DRM_USER:$DRM_USER" "$KRC"
    kreadconfig6 --file "$KRC" --group Compositing --key AllowTearing | grep -q true \
        && echo "TEARING-CONFIG OK (kwinrc Compositing/AllowTearing=true，desk-stop 会删)" \
        || echo "TEARING-CONFIG FAIL（写不进 kwinrc，本轮 vkmark -p immediate 会继续贴墙）"
    unset KRC
fi

# ---- 3) kwin 接管显示（SF 已随 stop 死亡，master 天然空闲）→ 先出桌面 ----
# 桌面进程的环境补丁：**接管轮是 runuser+env 起的，不过 PAM**，所以 pam_env 给常态桌面的
# 配置里，只有语言这一类是真的缺（09-25 用户实报"好多东西变英文"）：
#   /etc/default/locale 的 LANG/LC_ALL=zh_CN.UTF-8 ⇒ 缺了 kwin/plasma 就报
#   "Detected locale C … 不是 UTF-8"，界面退英文。值从文件现读，不在脚本里抄（抄了必漂移）。
#
# **血泪边界：MESA_* / TU_DEBUG 一律不注入。** 09-25 我照 kwin.log 里
# `EGL setup failed, disabling glamor → falling back to sw` 判定"接管轮一直软渲染"，
# 于是把 `/etc/environment` 的 `MESA_LOADER_DRIVER_OVERRIDE=kgsl` 喂进 kwin —— 结果 kwin 换到
# kgsl winsys，`kgsl_bo_new_dmabuf: Failed to allocate dma-buf` 刷 544 次、一帧都送不出去，
# **从"花屏"直接变成"纯黑且不回滚"**，用户只能强制重启。而这条噪音该怎么解读，
# 工作总结里已经写过两次：见 5.14/5.23 更正（"不是软件回退，Mesa 栈完整、vkmark 1w+ 分"）
# 与 5.34④ 旁边那条"同一噪音第三次误用"。**接管不需要动这套 Mesa**（见 §Mesa 结论：
# kgsl 缓冲只进不出，bo 导不出 dmabuf，KMS 直显方向相反）。
# 要判 GPU 到底用没用上，用下面的 GPU-WHICH 实测探针，不看日志措辞。
# 另外 `DISPLAY/WAYLAND_DISPLAY/QT_IM_MODULE/XMODIFIERS` 也**故意不收**：轮里走
# plasma-keyboard 路线（见上面 IM 段）；后面各条命令的 -u 仍会照摘。
# **env 的选项必须排在第一个 KEY=VALUE 之前**（5.28 的老坑，我今天又踩一次：写反 ⇒
# `env: '-u': No such file or directory` ⇒ kwin 没起 ⇒ 黑屏回滚）。
DESK_ENV=()
for f in /etc/default/locale /etc/environment; do
    [ -r "$f" ] || continue
    while IFS= read -r line; do
        case "$line" in ''|\#*) continue ;; esac
        case "$line" in *=*) ;; *) continue ;; esac
        case "$line" in
            LANG=*|LC_*=*|XCURSOR_SIZE=*|QT_QPA_PLATFORMTHEME=*)
                DESK_ENV+=("$line") ;;
        esac
    done < "$f"
done
# 10-02 实测（PyQt6 直接问 Qt，见《工作总结》§12.28）：轮里 kwin 的 env **没有** `XDG_CURRENT_DESKTOP`
# ⇒ Qt 选 `style=fusion` + `iconTheme=hicolor`：
#   · plasma-keyboard 的 shift/backspace/enter/语言/设置 这些键走 `Kirigami.Icon` ⇒ hicolor 里没有 ⇒ **键帽空白**；
#   · 全桌 KDE 组件退成旧样式（Fusion）。
# 只补这一点（实测最小集）就能回到 `breeze` + `breeze`；anland 正常是因为它的 kwin 由 startplasma 拉起、自带这些。
# 属"桌面身份"，功能必需、非个人偏好；写进 DESK_ENV 让六个启动点共用。
DESK_ENV+=(XDG_CURRENT_DESKTOP=KDE KDE_FULL_SESSION=true XDG_SESSION_TYPE=wayland)
# 10-02 深夜：zcode(Electron) 在有 WAYLAND_DISPLAY 的环境里被 auto-ozone 选成 Wayland
# ⇒ XTEST/XIM 输入链全部失效（§41.5/§41.12 的 X11 输入方案前提是 X11 客户端）。
# 显式钉回 X11（§41.6 同一开关的 x11 向；anland 不受影响——DESK_ENV 仅接管轮使用）。
DESK_ENV+=(ELECTRON_OZONE_PLATFORM_HINT=x11)
echo "DESK-ENV 补 ${#DESK_ENV[@]} 条: ${DESK_ENV[*]:-（空！/etc 那两份文件读不到，界面会继续变英文+软件渲染）}"
kill_linux_stack
rm -f $DIR/takeover.ok
env KWINWRAP_HIJACK=1 KWINWRAP_FILTER=1 KWINWRAP_SECCOMP=1 \
    KWINWRAP_UID=$DRM_UID KWINWRAP_GID=$DRM_UID KWINWRAP_BRIGHTNESS=2048 \
    KWINWRAP_USER=$DRM_USER \
    KWINWRAP_GROUPS="$(id -G "$DRM_USER" 2>/dev/null | tr ' ' ',')" \
    $DIR/bin/kwinwrap --out $LOGD/kwinatomic.log -- \
    env -u DISPLAY -u WAYLAND_DISPLAY ${DESK_ENV[@]+"${DESK_ENV[@]}"} HOME="$DRM_HOME" \
        KWIN_DRM_DEVICES=/dev/dri/card0 \
        KWIN_IM_SHOW_ALWAYS=1 \
        PCKEYD_INPUT_SOCKET=$DRM_RT/pckeyd-input.sock \
        FD_MESA_DEBUG=noubwc \
        KWIN_WAYLAND_NO_PERMISSION_CHECKS=1 \
        XDG_SESSION_ID=bogus \
        XDG_RUNTIME_DIR=$DRM_RT \
        DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$DRM_UID/bus \
        kwin_wayland --socket=taketest --xwayland \
    > $LOGD/kwin.log 2>&1 &
KPID=$!
sleep 6
kill -0 $KPID 2>/dev/null || rollback "kwin died (see kwin.log)"
runuser -u "$DRM_USER" -- env -u DISPLAY WAYLAND_DISPLAY=taketest \
    HOME="$DRM_HOME" XDG_RUNTIME_DIR=$DRM_RT \
    QT_QPA_PLATFORM=wayland \
    timeout 5 wayland-info > $LOGD/wayland-info.log 2>&1
[ $? = 0 ] || rollback "wayland-info self-check failed"
# 第二处阶段边界：kwin 已持住 card0 且 wayland 协议自检通过 = **画面此刻已经上屏**
# （此后才是起 Plasma 组件；drm-tui 用它把"kwin 上屏"和"桌面就绪"分开显示）。
# 注意与既有教训一致：这条只代表"kwin 活着且能应答"，**不代表 plasmashell 起来了**（§7 判据纪律）。
# ---- 上屏闸门：kwin 活着 ≠ 画面在出。必须看到它真的提交过 atomic 才算接管成功。
# 10-01 测试容器就是栽在这：kwin 选了 anland 后端，进程健康、wayland 自检通过，
# 但一次 atomic 都没提交 → 黑屏且脚本不回滚 → 用户只能强启。
KWIN_OK=0
for _i in 1 2 3 4 5 6 7 8; do
    if [ -s $LOGD/kwinatomic.log ] && grep -q ATOMIC $LOGD/kwinatomic.log; then KWIN_OK=1; break; fi
    sleep 2
done
if [ "$KWIN_OK" != 1 ]; then
    kill -0 $KPID 2>/dev/null && echo "KWIN-UP 有 kwin 进程但 0 条 ATOMIC 提交（后端选错？查 kwin.log 的 backend 行）"
    rollback "no atomic commit seen: kwin is up but nothing was scanned out (black screen guard)"
fi
echo "KWIN-UP kwin 已接管显示并实际提交上屏 $(date +%T)（ATOMIC 计数 $(grep -c ATOMIC $LOGD/kwinatomic.log)，正在起桌面组件）"
# ---- 3a-0) 轮 kwin 绑定的 X display 探测（10-02 晚定稿，§12.41）----
# display_daemon（宿主保活）会在 anland 死后 ~2s 整体重拉 anland（17:35:00 实锤：stop 后 2s
# startplasma 再起），重拉的 anland kwin 的 Xwayland 抢走 :0（带 -auth）。而轮 kwin 的
# Xwayland 是**按需**起的：kwin 先把下一个空闲 display 的 socket 绑在自己 fd 上
# （/tmp/.X11-unix/XN，lsof 实锤 17:35 轮 kwin 握着 X1），第一个客户端连上来才 spawn 进程。
# ⇒ :0 属于幽灵、写死必错；整轮的 display 号一律从轮 kwin 的绑定 socket 现场探测。
KP2=$(pgrep -P $KPID -x kwin_wayland | head -1); KP2=${KP2:-$KPID}
XDISCOVER=""
for _i in $(seq 1 10); do
    XDISCOVER=$(lsof -p "$KP2" 2>/dev/null | grep -o "/tmp/.X11-unix/X[0-9]*" | head -1)
    [ -n "$XDISCOVER" ] && break
    sleep 1
done
XNUM=$(basename "${XDISCOVER:-X0}" | tr -d X)
XNUM=${XNUM:-0}
XWARGS=("DISPLAY=:${XNUM}")
XD=":${XNUM}"
echo "XDISPLAY-DETECTED 轮 kwin 绑定 display=$XD（${XDISCOVER:-未发现绑定，回落 :0}）$(date +%T)"
# ---- 3a) XWayland（09-24：DRM 桌面缺它，X11-only 应用全打不开——星火商店/ZCode 是
#      Electron 默认 x11 ozone，报 "Missing X server or $DISPLAY"；usb-manager 的 PyQt5
#      源码里硬把 QT_QPA_PLATFORM=wayland 改写成 xcb，连退路都没有）。
#      KWin 6 的 Xwayland 按需起：kwin 绑 socket（上面探测到号）⇒ 第一个客户端连上来
#      才 spawn 进程 ⇒ 会话里注入这个号，第一个 X11 应用就是"第一个客户端"。
#      按需起的 Xwayland 不带 -auth，本地免 cookie 可连（10-02 实测）。
# ---- 3a-2) 会话激活环境归一（10-02，修"菜单点开的应用打不开 / VKB 只在个别应用弹"）----
# 菜单/收藏/桌面图标启动的应用不是 plasmashell 的直接 fork：kicker 把它们包进
# `systemd-run --user --scope`（10-02 实测 anland 里 app-org.kde.konsole-*.scope /
# app-zcode-*.scope 在跑），scope 进程的环境取自 **systemd --user 管理器**，而那份环境是：
#   · 镜像 /etc/environment 自带的 IM 变量：QT_IM_MODULE/GTK_IM_MODULE=fcitx5（systemctl
#     --user show-environment 实测；开发机 09-23 已把这几个从 /etc/environment 删掉 = §411
#     "修 DRM 虚拟键盘的必要动作"，这份镜像又带回来了）；
#   · WAYLAND_DISPLAY=wayland-0 —— anland 的 socket，轮里已被 kill_linux_stack 清掉（死值）。
# ⇒ scope 里的应用连 wayland-0（死 socket）→ Wayland 应用打不开；QT_IM_MODULE=fcitx5
#   → Qt/GTK 走 fcitx5 直连、不进 text-input → kwin 的 plasma-keyboard 永不自动弹。
# 修法 = 学 startplasma-wayland 干的事：把 systemd+dbus 激活环境显式归一到轮值。
# IM 变量置**空**（Qt/GTK 对空值回落默认= text-input，等同 unset）；XMODIFIERS 保留
# @im=fcitx5（X11 中文走旁观 fcitx5 的路径不变，见 FCITX5-BYST 段）。
# 放在 kactivitymanagerd 总线检查之后：systemd --user 若被 kill_linux_stack 带走，
# 总线在那一刻已经重新可用（上面那步实测过），ACTENV 才不会白写。
normalize_activation_env() {
    if runuser -u "$DRM_USER" -- env DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$DRM_UID/bus \
            XDG_RUNTIME_DIR=$DRM_RT HOME="$DRM_HOME" \
            dbus-update-activation-environment --systemd \
            DISPLAY=:0 WAYLAND_DISPLAY=taketest \
            QT_IM_MODULE= GTK_IM_MODULE= SDL_IM_MODULE= GLFW_IM_MODULE= \
            XMODIFIERS=@im=fcitx5 2>/dev/null; then
        echo "ACTENV-OK 激活环境已归一到轮值（DISPLAY=$XD WAYLAND_DISPLAY=taketest，QT/GTK/SDL/GLFW IM 置空）$(date +%T)"
    else
        echo "ACTENV-FAIL $(date +%T): systemd/dbus 激活环境没写成 ⇒ 菜单启动的应用会拿 anland 旧值（打不开/不弹键盘）"
    fi
}
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
nohup runuser -u "$DRM_USER" -- env -u DISPLAY -u QT_IM_MODULE -u GTK_IM_MODULE -u XMODIFIERS \
    ${DESK_ENV[@]+"${DESK_ENV[@]}"} QT_QPA_PLATFORM=wayland WAYLAND_DISPLAY=taketest \
    HOME="$DRM_HOME" XDG_RUNTIME_DIR=$DRM_RT \
    DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$DRM_UID/bus \
    /usr/lib/aarch64-linux-gnu/libexec/kactivitymanagerd > $LOGD/kactivitymanagerd.log 2>&1 &
for i in $(seq 1 10); do
    runuser -u "$DRM_USER" -- env DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$DRM_UID/bus \
        gdbus call --session --dest org.freedesktop.DBus --object-path /org/freedesktop/DBus \
        --method org.freedesktop.DBus.ListNames 2>/dev/null | grep -q org.kde.ActivityManager && break
    sleep 1
done
runuser -u "$DRM_USER" -- env DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$DRM_UID/bus \
    gdbus call --session --dest org.freedesktop.DBus --object-path /org/freedesktop/DBus \
    --method org.freedesktop.DBus.ListNames 2>/dev/null | grep -q org.kde.ActivityManager \
    || echo "WARN: kactivitymanagerd not on bus, plasmashell may abort (see kactivitymanagerd.log)"
# 总线确认可用，先把激活环境归一到轮值（见上面 3a-2 注释），再起壳。
normalize_activation_env
# plasmashell 的启动命令必须是**可重入**的：蓝牙适配器出现得比壳晚（实测 20:32:33 起壳、
# 20:33:22 才有 Powered: yes），bluedevil 的托盘 applet 与系统设置页在"根本没有适配器"的时刻
# 做完判断就不会自己回读 ⇒ 托盘无图标 + 设置显示"已禁用"，而鼠标其实照连。
# 所以 5c 里蓝牙上电后要再拉一次同一个壳（`--replace` 自带替换旧实例，不需要 kill）。
start_plasmashell() {
    nohup runuser -u "$DRM_USER" -- env -u QT_IM_MODULE -u GTK_IM_MODULE \
        -u SDL_IM_MODULE -u GLFW_IM_MODULE XMODIFIERS=@im=fcitx5 "${XWARGS[@]}" ${DESK_ENV[@]+"${DESK_ENV[@]}"} \
        WAYLAND_DISPLAY=taketest \
        HOME="$DRM_HOME" XDG_RUNTIME_DIR=$DRM_RT \
        DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$DRM_UID/bus \
        QT_QPA_PLATFORM=wayland \
        /usr/bin/plasmashell --replace >> $LOGD/plasma.log 2>&1 &
}
start_plasmashell
# plasmashell 起没起必须亲眼看到（09-24 黑屏事故的直接教训：`env` 参数顺序写错
# → plasmashell 压根没启动，而收尾那行照旧写 "plasma up"，连着三轮黑屏白猜）。
PSHELL=""
for i in 1 2 3 4 5 6 7 8; do
    PSHELL=$(pgrep -x plasmashell | head -1)
    [ -n "$PSHELL" ] && break
    sleep 1
done
if [ -n "$PSHELL" ]; then
    echo "PLASMA-UP pid=$PSHELL $(date +%T)"
else
    echo "PLASMA-FAIL $(date +%T): plasmashell 没起来 = 无壳黑屏，plasma.log 尾部："
    tail -n 5 $LOGD/plasma.log 2>&1
fi
# ---- 4b) kded5：接管轮里**从来没人起它** ⇒ 所有 kded 模块不加载。
# 直接现象就是用户 09-25 报的"右下角看不到蓝牙"：bluedevil 的托盘图标与配对接缝（agent）
# 都是 kded 模块（§26.5 当时只记了"要 plasmashell 重启一次才加载"，其实根本没人拉起 kded）。
# 本机是 KF6：二进制叫 /usr/bin/kded6（常态会话里 pid 1563 就是它，由 startplasma-wayland 带起）。
# 之前我 glob 了 kded5/libexec 两处，全落空 ⇒ 13:03 轮报 KDED-SKIP，等于这条修复压根没生效。
KDED=$(ls /usr/bin/kded6 /usr/bin/kded5 /usr/libexec/kded5 /usr/lib/*/kded5 2>/dev/null | head -1)
KDNAME=$(basename "$KDED" 2>/dev/null)   # KF6 那份叫 kded，判活必须跟着实际名字走
if [ -n "$KDED" ]; then
    nohup runuser -u "$DRM_USER" -- env -u DISPLAY -u QT_IM_MODULE -u GTK_IM_MODULE \
        -u SDL_IM_MODULE -u GLFW_IM_MODULE XMODIFIERS=@im=fcitx5 \
        ${DESK_ENV[@]+"${DESK_ENV[@]}"} WAYLAND_DISPLAY=taketest XDG_CURRENT_DESKTOP=KDE XDG_SESSION_TYPE=wayland \
        HOME="$DRM_HOME" XDG_RUNTIME_DIR=$DRM_RT \
        DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$DRM_UID/bus \
        QT_QPA_PLATFORM=wayland "$KDED" > $LOGD/kded.log 2>&1 &
    KDPID=""
    for i in 1 2 3 4 5; do
        KDPID=$(pgrep -x "$KDNAME" | head -1)
        [ -n "$KDPID" ] && break
        sleep 1
    done
    if [ -n "$KDPID" ]; then
        echo "KDED-UP pid=$KDPID $(date +%T)（bluedevil 托盘图标/配对接缝的宿主）"
    else
        echo "KDED-FAIL $(date +%T): $KDED 没起来 ⇒ 蓝牙图标一类 kded 件仍然缺席，kded.log 尾部："
        tail -n 5 $LOGD/kded.log 2>&1
    fi
else
    echo "KDED-SKIP 容器里找不到 kded5（装 kde-cli-tools/plasma-workspace 哪个包带的？）"
fi
# ---- 4b') 物理音量键（09-30 定案）----
# 取证：音量+/-的事件链本身是通的——按键由内核 virtual 设备 "Xiaomi Consumer"(event10)
# 报 KEY_VOLUMEUP/DOWN(115/114)，kwin 经 libinput 已把它当 seat0 键盘收到；
# kglobshortcutsrc 里 [kmix] increase/decrease_volume 也绑着。断点=接管轮里 kded6 **不会自动加载**
# audioshortcutsservice（音量快捷键处理者，注册名 kmix）⇒ kwin /component/kmix isActive=false，
# 按键到达后无人处理（物理键和 xdotool 注入一起哑）。显式 loadModule 修复，实测音量随按键变化。
if [ -n "$KDPID" ]; then
    sleep 2
    KDOWNER=$(XDG_RUNTIME_DIR=$DRM_RT DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$DRM_UID/bus \
        runuser -u "$DRM_USER" -- busctl --user status org.kde.kded6 2>/dev/null | sed -n 's/^PID=//p' | head -1)
    echo "KDED6-OWNER org.kde.kded6 属主 pid=${KDOWNER:-无}（脚本拉的 kded=$KDPID；不一致 ⇒ 名字被重拉会话占用）$(date +%T)"
    AK=$(XDG_RUNTIME_DIR=$DRM_RT DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$DRM_UID/bus \
        runuser -u "$DRM_USER" -- busctl --user call org.kde.kded6 /kded org.kde.kded6 \
        loadModule s audioshortcutsservice 2>&1)
    # ⚠ loadModule 的返回值不能当判据（10-01 在同一批里撞到的同类假阳性）：
    #   它在模块根本没装好、甚至 kded 不认这个名字时也回 "b true"。
    #   硬判据 = 那个 .so 真的映射进了 kded 的地址空间（与 kwin 补丁同一路数：只看实测，不看措辞）。
    AHITS=0
    for _ak in 1 2 3 4 5 6; do
        AHITS=$(grep -c "audioshortcutsservice" /proc/$KDPID/maps 2>/dev/null)
        AHITS=${AHITS:-0}
        [ "$AHITS" -gt 0 ] && break
        sleep 1
    done
    if [ "$AHITS" -gt 0 ]; then
        echo "AUDIOKEY-OK audioshortcutsservice 已映射进 kded(pid=$KDPID)，maps 命中 $AHITS 条 $(date +%T)"
    else
        echo "AUDIOKEY-PENDING $(date +%T): kded(pid=$KDPID) 起跑窗口内未映射 audioshortcutsservice（loadModule 返回: $AK）⇒ 音频系统就绪后自动重试，看 AUDIOKEY-RETRY 行"
        AUDIOKEY_PENDING=1
    fi
fi
# ---- 4c) 虚拟键盘原生弹出（09-27 §41.7）----
# kwin env 已加 KWIN_IM_SHOW_ALWAYS=1（官方开关，inputmethod.cpp shouldShowOnActive）：
# 每次窗口激活（含 X11/XWayland 应用——它们没有 text-input 协议，之前 VKB 永不弹出）
# kwin 走原生路径弹出 VKB；anland 的 kwin 不带此 env，行为不变。
# 屏幕键盘面板=kwin 按 InputMethod 登记自拉的 plasma-keyboard（顺序配方见上面 IM 段;
# scripts/vkb-show.sh（桌面启动器「显示虚拟键盘」，总线自动探测两模式通吃）。
# ---- 托盘亮度/电池（09-24 三根因定修）----
# 1) 容器 /sys 挂成 ro → backlighthelper 写亮度 EROFS；remount rw 解决
# 2) 无 logind active session → polkit 默认拒 org.kde.powerdevil.backlighthelper.*
# 3) DRM 会话不走 startplasma，powerdevil 守护根本没人拉
mount -o remount,rw /sys 2>/dev/null || echo "WARN: /sys remount failed, brightness slider will be read-only"
cat > /etc/polkit-1/rules.d/61-powerdevil-backlight.rules <<'EOF'
polkit.addRule(function(action, subject) {
    if (action.id.indexOf("org.kde.powerdevil.backlighthelper.") === 0 &&
        subject.user === "__DRM_USER__") {
        return polkit.Result.YES;
    }
});
EOF
# ⚠ 必须在**重启 polkit 之前**把占位符换成真实用户名。
# 10-01 实证的坏法：37acfdb（09-30 23:53 参数化）把规则里的用户名改成 __DRM_USER__，
# 而替换的 sed 留在脚本末尾 —— 本轮日志的顺序是 `restart polkit`(3181 行) →
# POWERDEVIL-OK(3217 行) → `sed __DRM_USER__`(3702 行)：polkit 重载规则时文件里还是占位符，
# powerdevil 启动那一刻授权不到 backlighthelper，`DisplaysDBusNames` 恒为 `as 0`，
# 托盘亮度滑块整个不出现（09-30 21:14 那轮的版本 7260d33 是直接写死 "xieyizhou"，所以一直好的）。
# 同理 60-nm-drm.rules / 61-bluez-drm-lock.conf 也必须当场落地，别等末尾统一补。
sed -i "s/__DRM_USER__/$DRM_USER/g" /etc/polkit-1/rules.d/61-powerdevil-backlight.rules 2>/dev/null
# 09-24 假设：同轮两处 try-restart polkit 恰好撞在 NM 启动的 polkit 权限查询窗口上
# → 10:47 轮 NM 主循环冻结。这里改成唯一一次 restart，并等 polkit 真正 active 再继续。
systemctl restart polkit 2>/dev/null
for i in $(seq 1 10); do systemctl is-active polkit >/dev/null 2>&1 && break; sleep 0.5; done
# ---- 亮度依赖 KScreen，必须在 powerdevil 之前起来 ----
# 实测：powerdevil 的 /org/kde/ScreenBrightness 只在**启动那一刻**枚举一次可亮度设备，
# 之后再没有刷新过 —— 本轮里 `DisplaysDBusNames` 恒为 `as 0`，托盘亮度滑块因此整个不出现
# （polkit 已授权、/sys 已 rw、节点可写，都不是拦路的）。
# 而接管轮不走 startplasma，没人激活 org.kde.KScreen：它由 D-Bus 服务
# /usr/share/dbus-1/services/org.kde.kscreen.service 定义，Exec=kscreen_backend_launcher。
# 所以这里显式把它拉起来，等它真的在跑，再启动 powerdevil。
KSVC=$(ls /usr/lib/*/libexec/kf6/kscreen_backend_launcher 2>/dev/null | head -1)
if [ -n "$KSVC" ]; then
    nohup runuser -u "$DRM_USER" -- env -u DISPLAY -u QT_IM_MODULE \
        ${DESK_ENV[@]+"${DESK_ENV[@]}"} WAYLAND_DISPLAY=taketest \
        HOME="$DRM_HOME" XDG_RUNTIME_DIR=$DRM_RT \
        DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$DRM_UID/bus \
        QT_QPA_PLATFORM=wayland \
        "$KSVC" > $LOGD/kscreen.log 2>&1 &
    KSUP=""
    for _ks in 1 2 3 4 5 6 7 8; do
        KSUP=$(pgrep -f kscreen_backend_launcher | head -1)
        [ -n "$KSUP" ] && break
        sleep 1
    done
    if [ -n "$KSUP" ]; then echo "KSCREEN-OK pid=$KSUP $(date +%T)（powerdevil 的亮度设备来自它）"
    else echo "KSCREEN-FAIL $(date +%T): kscreen_backend_launcher 没起来，powerdevil 会枚举到 0 个亮度设备；kscreen.log 尾部："
        tail -n 5 $LOGD/kscreen.log 2>&1
    fi
else
    echo "KSCREEN-SKIP 容器里没有 kscreen_backend_launcher（缺 libkscreen 的 qt6 plugin 包？）"
fi
PDEV=$(ls /usr/lib/*/libexec/org_kde_powerdevil 2>/dev/null | head -1)
[ -n "$PDEV" ] && nohup runuser -u "$DRM_USER" -- env -u DISPLAY -u QT_IM_MODULE \
    ${DESK_ENV[@]+"${DESK_ENV[@]}"} WAYLAND_DISPLAY=taketest \
    HOME="$DRM_HOME" XDG_RUNTIME_DIR=$DRM_RT \
    DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$DRM_UID/bus \
    QT_QPA_PLATFORM=wayland \
    "$PDEV" > $LOGD/powerdevil.log 2>&1 &
# 亮度滑条/电池的宿主是 powerdevil：起没起必须有硬判据。
# 09-24 那三条根因（/sys ro、polkit 无 logind 默认拒、没人拉 powerdevil）里，
# 前两条脚本自己有回显，唯独"没拉起来"过去是静默的 ⇒ 轮里亮度拖不动只能靠猜。
# 10-01 用户报"接管模式右下角调不了亮度"，日志里确实一条 powerdevil 判据都没有。
PDALIVE=""
for _pd in 1 2 3 4 5 6; do
    PDALIVE=$(pgrep -f "org_kde_powerdevil" | head -1)
    [ -n "$PDALIVE" ] && break
    sleep 1
done
if [ -z "$PDEV" ]; then
    echo "POWERDEVIL-FAIL $(date +%T): 找不到 /usr/lib/*/libexec/org_kde_powerdevil（powerdevil 包没装？）⇒ 托盘亮度与电池不可用"
elif [ -n "$PDALIVE" ]; then
    echo "POWERDEVIL-OK pid=$PDALIVE $(date +%T)（托盘亮度/电池的宿主）"
else
    echo "POWERDEVIL-FAIL $(date +%T): 拉起了但 6 秒内不在了，powerdevil.log 尾部："
    tail -n 6 $LOGD/powerdevil.log 2>&1
fi
# 亮度终检：判据是 powerdevil 自己报的亮度设备数量（`as 0` = 托盘没有滑块）。
# 只看进程活着不算数 —— 本轮 powerdevil 一直活着，但 DisplaysDBusNames 始终是 0。
BRC=""
for _br in 1 2 3 4 5 6 7 8 9 10; do
    BRC=$(XDG_RUNTIME_DIR=$DRM_RT DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$DRM_UID/bus \
        runuser -u "$DRM_USER" -- busctl --user get-property org.kde.org_kde_powerdevil \
        /org/kde/ScreenBrightness org.kde.ScreenBrightness DisplaysDBusNames 2>/dev/null)
    case "$BRC" in
        "as 0"|""|"as") ;;
        *) break ;;
    esac
    sleep 1.5
done
case "$BRC" in
    ""|*"No such"*|*Failed*) echo "BRIGHTNESS-FAIL $(date +%T): 读不到 ScreenBrightness.DisplaysDBusNames（powerdevil 的亮度对象不存在）⇒ 托盘亮度不可用";;
    "as 0") echo "BRIGHTNESS-FAIL $(date +%T): powerdevil 报 0 个可亮度设备 ⇒ 托盘滑块不会出现（KScreen 时序问题，见上面 KSCREEN-* 行）";;
    *) echo "BRIGHTNESS-OK $(date +%T): $BRC";;
esac
# 任务栏点击启动应用走 xdg-desktop-portal；不带 KDE 环境起来的话只有 gtk 后端
nohup runuser -u "$DRM_USER" -- env -u DISPLAY -u QT_IM_MODULE -u GTK_IM_MODULE \
    -u SDL_IM_MODULE -u GLFW_IM_MODULE XMODIFIERS=@im=fcitx5 \
    ${DESK_ENV[@]+"${DESK_ENV[@]}"} WAYLAND_DISPLAY=taketest XDG_CURRENT_DESKTOP=KDE XDG_SESSION_TYPE=wayland \
    HOME="$DRM_HOME" XDG_RUNTIME_DIR=$DRM_RT \
    DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$DRM_UID/bus \
    QT_QPA_PLATFORM=wayland \
    /usr/libexec/xdg-desktop-portal > $LOGD/portal.log 2>&1 &
touch $DIR/takeover.ok
$DIR/bin/setbright 2048 > /dev/null 2>&1
echo "DESKTOP-UP $(date +%T) kwin pid $KPID"
# ---- 4a-2) GPU 实测（后台，不阻塞）：**判有没有硬渲染只认这个，不认 kwin.log 的措辞** ----
# 09-25 教训：kwin.log 里 "disabling glamor / falling back to sw" 是 Xwayland 开不到
# renderD128 时 Xwayland 自己的输出，历史上已三次被误读成"整个桌面软渲染"（vkmark 1w+ 早就
# 证否过一次）。这里直接问渲染器名字：
#   Adreno …        = kgsl DRI 硬渲染
#   zink Vulkan …   = 默认路径（turnip 过 Vulkan），同样是硬渲染 —— 接管轮 21 轮一直是这条
#   llvmpipe        = 真软渲染，才算问题
# 探针不成立时打 NO-PROBE（glxinfo 没输出/连不上 :0），绝不说成"没有 GPU"。
(
    sleep 12
    R=$(runuser -u "$DRM_USER" -- env DISPLAY="$XD" timeout 12 glxinfo -B 2>/dev/null | sed -n 's/^OpenGL renderer string: //p' | head -1)
    case "$R" in
        *llvmpipe*) echo "GPU-WHICH $(date +%T): $R ⇒ **软渲染**，Xwayland 打不开 render 节点（查补充组/GPU-NODE）" ;;
        "")         echo "GPU-WHICH $(date +%T): NO-PROBE（glxinfo 无输出/连不上 $XD）⇒ 这条没测到，别当作没有 GPU" ;;
        *)          echo "GPU-WHICH $(date +%T): $R ⇒ 硬渲染可用" ;;
    esac
) &

# ---- 4a) XWayland 事后核对（异步，不阻塞桌面）：轮 kwin 绑定的 display（XD）已注入
#      全会话；这里只核实它的 Xwayland 进程出现没有（按需起 ⇒ 第一个 X11 客户端连上来
#      才出现，XWAYLAND-PENDING 属正常）。10-02 教训：pgrep 第一条 Xwayland 可能是
#      display_daemon 重拉的 anland 幽灵的（它抢 :0），所以仍按父进程认亲。
(
    # 先主动当一个客户端：触发按需 Xwayland 真正 spawn（否则它要等第一个应用连入）
    runuser -u "$DRM_USER" -- env DISPLAY="$XD" XDG_RUNTIME_DIR=$DRM_RT timeout 5 xdpyinfo >/dev/null 2>&1
    KP2=$(pgrep -P $KPID -x kwin_wayland | head -1)
    [ -z "$KP2" ] && KP2=$KPID
    for i in $(seq 1 30); do
        XP=""
        for p in $(pgrep -x Xwayland); do
            [ "$(ps -o ppid= -p $p 2>/dev/null | tr -d ' ')" = "$KP2" ] && { XP=$p; break; }
        done
        [ -n "$XP" ] && break
        sleep 1
    done
    if [ -z "$XP" ]; then
        echo "XWAYLAND-PENDING $(date +%T): display=$XD 的 socket 已由轮 kwin 绑定，尚无客户端连入 ⇒ 还没按需 spawn（第一个 X11 应用打开时就会出现）"
    else
        XD2=$(tr '\0' '\n' < /proc/$XP/cmdline 2>/dev/null | grep -E '^:[0-9]+$' | head -1)
        echo "XWAYLAND-OK display=$XD2 pid=$XP（轮注入 $XD）$(date +%T)"
        XAF=$(tr '\0' '\n' < /proc/$XP/cmdline 2>/dev/null | grep -A1 -- '^-auth$' | tail -1)
        if [ -n "$XAF" ] && [ -r "$XAF" ]; then
            runuser -u "$DRM_USER" -- env DISPLAY="$XD" XAUTHORITY="$XAF" \
                xhost +si:localuser:"$DRM_USER" >/dev/null 2>&1 \
                && echo "XAUTH-GRANT OK auth=$XAF localuser 授权已加 $(date +%T)"
        fi
        # ---- X11 应用缩放（10-02 深夜）：anland 的 Xwayland 根窗口带 Xft.dpi=Scale×96
        # （实测 Xft.dpi: 192），X11 应用靠它放大；轮的按需 Xwayland 没人写 ⇒ 96dpi 极小。
        # 这里按 kwinrc 的 Scale 现算现写（与 dev 容器同款配置等价）。
        XSCALE=$(grep -A1 '\[Xwayland\]' "$DRM_HOME/.config/kwinrc" 2>/dev/null | grep -o 'Scale=[0-9]*' | cut -d= -f2 | head -1)
        XSCALE=${XSCALE:-1}
        XDPI=$((XSCALE * 96))
        printf 'Xft.dpi: %s\n' "$XDPI" | runuser -u "$DRM_USER" -- env DISPLAY="$XD" XDG_RUNTIME_DIR=$DRM_RT \
            xrdb -merge - 2>/dev/null \
            && echo "XFTDPI-OK display=$XD Xft.dpi=$XDPI（X11 应用缩放=Scale $XSCALE）$(date +%T)" \
            || echo "XFTDPI-FAIL $(date +%T): xrdb 没写成（X11 应用会偏小；手工等价：printf 'Xft.dpi: $XDPI' | DISPLAY=$XD xrdb -merge -）"
    fi
# ---- pc-keyd v2（组合键守护，XTEST/EIS 后端）----
        # 必须 kwin+Xwayland 就绪后启动（连接 X :0 注入）；以会话用户运行（root 的 X 连接
        # 被拒，13:41 轮实测）。v2 不创建 uinput 设备 → 安卓"物理键盘"通知消失；
        # 显示号写入 /run/pc-keyd-display 供其 _xdisplay() 读取。
        echo "$XD" > /run/pc-keyd-display
        pkill -f "pc-keyd.py" 2>/dev/null
        nohup runuser -u "$DRM_USER" -- env DISPLAY="$XD" HOME="$DRM_HOME" \
            XDG_RUNTIME_DIR=$DRM_RT             PCKEYD_INPUT_SOCKET=$DRM_RT/pckeyd-input.sock             DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$DRM_UID/bus             python3 /usr/local/bin/pc-keyd.py > /tmp/pc-keyd.log 2>&1 &
        sleep 1
        if curl -s -o /dev/null -w '%{http_code}' --max-time 3 http://127.0.0.1:48222/ping | grep -q 204; then
            echo "PC2-UP $(date +%T) (xtest backend, display=$XD)"
        else
            echo "PC2-FAIL $(date +%T): pc-keyd v2 未就绪（PC 页组合键本轮不可用，不阻塞）"
        fi
        # ---- fcitx5 旁观守护（09-29 晚,复刻 08:56→09:20 你实测成功的**顺序**）----
        # 成功态三要素,顺序是关键：
        #   ① kwinrc InputMethod=plasma-keyboard 起跑 → kwin 登记并自拉 plasma-keyboard,
        #      弹出机制全程可用（弹窗跟着"键盘 app 登记"走,和守护无关）；
        #   ② 轮起来**之后**再补拉带 WAYLAND_DISPLAY 的 fcitx5：imv2 先到先得,它晚到一步
        #      只能当旁观者（不抢面板名额）,但 XIM/dbus 前端全功能——轮内 zcode/星火等
        #      X11 应用的 Ctrl+Space 经应用转发给 fcitx5,实测可用（09:21 你原话）；
        #   ③ 本段负责那个"轮起来之后"的守护+`-c` 置默认英文。
        # 对照失败态:开机就抢座（座位=fcitx5）→ 面板名额没了=12:56/14:16 轮;
        # 守护剥 WAYLAND_DISPLAY 开机拉 → X11 热键也死=10:0x 轮。
        pkill -x fcitx5 2>/dev/null; sleep 1
        nohup runuser -u "$DRM_USER" -- env WAYLAND_DISPLAY=taketest DISPLAY="$XD" HOME="$DRM_HOME" \
            XDG_RUNTIME_DIR=$DRM_RT DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$DRM_UID/bus \
            fcitx5 -d > $LOGD/fcitx5-round.log 2>&1 &
        FC5=0
        for i in $(seq 1 8); do
            runuser -u "$DRM_USER" -- env DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$DRM_UID/bus \
                fcitx5-remote --check >/dev/null 2>&1 && { FC5=1; break; }
            sleep 1
        done
        if [ "$FC5" = 1 ]; then
            runuser -u "$DRM_USER" -- env DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$DRM_UID/bus \
                fcitx5-remote -c >/dev/null 2>&1
            # ---- 热换座位实验已撤回(09-29 15:2x 证伪)----
            # 曾按"09:05 手测态"推断 reconfigure 能把 IM 座位换给 fcitx5 而面板注册不动;
            # 现场验证:换后 konsole 依旧 0 wayland IC(konsole_xwin 实验)、X11 通道 C 键被
            # 座位 QtVK 吞(xdotool XTEST 1→2 对比实锤)——reconfigure 不重绑键盘中继,
            # 热换无意义。Ctrl+Space 改走 pc-keyd 的 fcitx5-remote -T 特判(droid-pc-keyboard
            # 09-29 提交),座位保持 plasma-keyboard=弹窗满血。
            echo "FCITX5-BYST OK 旁观守护就绪 默认英文 display=$XD $(date +%T)"
        else
            echo "FCITX5-BYST FAIL: fcitx5 未上总线（本轮 X11 中文/Ctrl+Space 不可用，不阻塞）—— 看 fcitx5-round.log"
        fi
) >> $LOGD/desk-takeover.log 2>&1 &

    # ---- 5) 容器接管 WiFi：NetworkManager 模式（DRM 桌面设置里可直接点热点、密码持久化） ----
    # 备份安卓策略路由后再动 rule——netd 已死没人管；desk-stop 会原样还原再 start。
    # 09-24 下午两连实锤：①`ip rule save` 是 iproute2 二进制格式，desk-stop 的
    # `ip rule restore` 原样回放 → save 时若带脏 pref0，每轮都被 bak 带病重启；
    # ②12:20 轮 dedup 到 1 后，轮内又漂回 2 条 pref0（无任何脚本再碰 rule）→
    # 备份前先收敛到只剩一条，从源头保证 bak 干净。
    while [ "$(ip -o rule show | grep -c '^0:')" -gt 1 ]; do
        ip rule del pref 0 table local 2>/dev/null || break
    done
    ip rule save > /run/desk-ip-rules.bak 2>/dev/null
    # 精确化（09-25）：容器有独立 PID ns，`-x` 在这里看不到安卓的 supplicant，本来就不致命中；
    # 但按 desk-wpa.pid + `-u` 特征杀仍然更正确——它同时清掉"NM 经 D-Bus 激活的容器 systemd 版"，
    # 并且若将来这段被挪到安卓 ns 里执行（run()），不会变成 5.30 那种无差别杀。LEAK 只点名不动手。
    if [ -f /run/desk-wpa.pid ]; then
        kill "$(cat /run/desk-wpa.pid)" 2>/dev/null
        rm -f /run/desk-wpa.pid
    fi
    pkill -9 -f 'wpa_supplicant -u' 2>/dev/null
    pgrep -fa wpa_supplicant | grep -v ' -u' >/dev/null 2>&1 && \
        echo "WPA-KEEP(安卓侧实例，容器 ns 本不可见，仅记录) $(date +%T)"
    pkill -x dhcpcd 2>/dev/null
    if command -v NetworkManager >/dev/null 2>&1; then
        # 【09-25 傍晚 根因实锤，见工作总结 5.36】这里原有的 down;sleep 1;up **永不进可信路径**：
        # STA 已连接 + 芯片 idle ~36min 时，down 硬拆链路（SYS MC STOP）后 1s 的 up 撞进 cnss 的
        # MHI 上电流程（POWER_ON -110 超时 → recovery ASSERT），`ip` 永久 D 在 cnss_idle_restart
        # 并持有 rtnl_lock —— 此后连只读 `ip link show` 都进 D，安卓 netd 一并冻结，只能强启。
        # 接管只需要 L3（地址/路由清理），supplicant/NM 在已 UP 的口上工作是常态路径；
        # "此刻是否 UP"的检查统一放到 WIFI-PRESTATE 之后（那里只读探测并置 WIFI_SKIP）。
        # 安卓把 main 表摘了、全塞 fwmark→1015，NM 的 DHCP 不吃这套 → 恢复内核标准三表
        ip rule flush
        ip rule add pref 0 table local        2>/dev/null
        ip rule add pref 100 table main       2>/dev/null
        ip rule add pref 32766 table default  2>/dev/null
        # 09-24 实锤：ip rule 曾堆到 24600 条（pref0 local 重复 24576 次），NM 启动的
        # 同步 link/rule dump 一次要 13s+。flush 在本内核不保证删净 pref0（实测会
        # 残留），逐条删到只剩一条（batch 版删除实测有效，这里单条循环更直白）。
        N0=$(ip -o rule show | grep -c '^0:')
        if [ "$N0" -gt 1 ]; then
            for d in $(seq 2 $N0); do ip rule del pref 0 table local 2>/dev/null || break; done
            echo "IPRULE-DEDUP removed=$(( N0 - $(ip -o rule show | grep -c '^0:') )) $(date +%T)"
        fi
        N0=$(ip -o rule show | grep -c '^0:')
        [ "$N0" -ne 1 ] && echo "IPRULE-ANOMALY pref0=$N0 $(date +%T)"
        # 09-24 12:4x：轮内出现"dedup 后无人操作却多回一条 pref0"的漂移，加一个只读
        # netlink 监听抓 re-adder 的现行（不碰 wlan0 流量）。只保留最近一轮的监听。
        pkill -f 'ip monitor rule' 2>/dev/null
        nohup ip monitor rule > $LOGD/ip-rule-monitor.log 2>&1 &
        ip -4 addr flush dev wlan0 2>/dev/null
        # 【5.36 方案 A】原来这三样靠 down/up 顺带清，现在禁 flap ⇒ 显式做（全是 L3，零 admin 动作）
        ip route flush dev wlan0 2>/dev/null
        ip -6 route flush dev wlan0 2>/dev/null
        ip neigh flush dev wlan0 2>/dev/null
    cat > /run/nm-drm.conf <<'EOF'
[main]
plugins=keyfile
[connectivity]
uri=
[keyfile]
# 回归根因补充实锤（09-24 下午读源码）：c27b36f 写的是 except:type=wifi;... ——
# 标签必须是 'type:'，'type=' 不是合法标签，该 except 谓词对任何设备都恒不命中，
# "除了 wifi 都 unmanaged" 的语义整个失效 → wlan0 每轮被判 unmanaged（回归轮的
# nmcli STATE=unmanaged 为证）。这里回到 09-23 上午实测可连的写法。
unmanaged-devices=except:type:wifi
# p2p0 排除为什么不能写进本行（nm-core-utils.c nm_match_spec_split/nm_match_spec_device）：
# ',' 与 ';' 完全同权、一律 OR；任一 except 命中即 NEG_MATCH（托管优先）——这套
# 语法根本表达不了"wifi 里再排除 p2p0"的 AND 取反。[device-*] 段也没有 managed 键
# （只存在于 /run/NetworkManager/devices/<ifindex> run-state，817eb6f 加的段实测零生效）。
# → p2p0 改走运行时 `nmcli dev set p2p0 managed no`（见 NM 启动等待段）。
[logging]
# 09-24 10:39 轮实锤：命令行 --log-level=DEBUG 在这套容器 journal 后端上完全无效
# （journal 里 debug 行数=0，NM 也没打 "Logging:" 自述行）→ 走官方 conf 路径。
# domains 必须显式带 DEFAULT:INFO，否则是白名单把整域静音（10:22 轮踩过）。
level=DEBUG
domains=DEFAULT:INFO,SUPPLICANT:DEBUG,DEVICE:DEBUG,WIFI:DEBUG,RFKILL:DEBUG,DBUS_PROPS:DEBUG
EOF
    mkdir -p /run/NetworkManager
    # NM 靠 D-Bus 激活 wpa_supplicant.service 拉起扫描/认证进程——它可以 disabled 但绝不能 masked
    systemctl unmask wpa_supplicant.service 2>/dev/null
    # plasma-nm 点击连接会被 polkit 拒（"Not authorized to control networking"，
    # 容器里无 logind active 会话）→ 给本用户放行 NM 动作（仅本机 DRM 场景）
    mkdir -p /etc/polkit-1/rules.d
    cat > /etc/polkit-1/rules.d/60-nm-drm.rules <<'EOF'
polkit.addRule(function(action, subject) {
    // 09-25 缺陷③：轮内"WiFi 总开关"对普通用户直接拒绝——实测关掉后 soft-block +
    // supplicant WoWLAN 半连接态，再开大概率失败还把 plasma UI 卡住（NM 重试风暴）。
    // 单条网络的连接/断开不受影响；root（本脚本的 nmcli radio wifi on 引导）不受影响。
    if (subject.user === "__DRM_USER__" &&
        (action.id === "org.freedesktop.NetworkManager.enable-disable-wifi" ||
         action.id === "org.freedesktop.NetworkManager.enable-disable-network" ||
         action.id === "org.freedesktop.NetworkManager.sleep-wifi"))
        return polkit.Result.NO;
});
polkit.addRule(function(action, subject) {
    if (action.id.indexOf("org.freedesktop.NetworkManager") === 0 && subject.user === "__DRM_USER__")
        return polkit.Result.YES;
});
EOF
    # （原本这里还有第二处 try-restart polkit，已删——见托盘段的说明）
    # 09-24 断网根因：昨晚 35a8bff 给 udevd 加的 ExecCondition(enable_hw_access) drop-in
    # 在今天 09:41 重启后条件不满足（container.config 里=0）→ udevd 永久 skipped。
    # NM platform 以 "use udev" 建 link 缓存：拿不到 udev 设备对象 → 所有 link 永远
    # not-init → startup complete 卡在 'lo (link-init)' → 全设备 unmanaged（WiFi 永远转圈）。
    # 起 NM 前保证 udevd 活着并做 net 冷插拔；systemd 拉不动就直接手动起。
    # 09-24 16:25 实锤（回安卓后 WiFi 永久失效、只能整机重启，两次）：udevd + 下面那行
    # `udevadm trigger --action=add --subsystem-match=net` 会用 80-net-setup-link 的
    # 可预测命名把共享 netns 里的 wlan0 改名成 wlp1s0
    # （安卓 dmesg: "cnss_pci 0000:01:00.0 wlp1s0: renamed from wlan0 (while UP)"），
    # 而安卓 WiFi 状态机硬编码只认 wlan0 → logcat "WifiActiveModeWarden: One of the
    # native daemons died. Triggering recovery" + "MiuiWifiService: This interface
    # cannot be used" 无限循环，设置里开关点了没反应。容器改名对安卓是永久的（安卓不会
    # 自己改回来），所以只有重启才好。处置：把命名规则掩掉（只动容器 rootfs 的 /etc，
    # 不碰安卓），udevd 照常活着供 NM 用。
    ln -sf /dev/null /etc/udev/rules.d/80-net-setup-link.rules
    systemctl reset-failed systemd-udevd.service 2>/dev/null
    systemctl start systemd-udevd.service 2>/dev/null
    if ! pgrep -x systemd-udevd >/dev/null; then
        nohup /usr/lib/systemd/systemd-udevd >/dev/null 2>&1 &
        sleep 1
    fi
    udevadm trigger --action=add --subsystem-match=net 2>/dev/null
    udevadm settle --timeout=5 2>/dev/null
    echo "UDEVD_PID=$(pgrep -x systemd-udevd | head -1) NETRULES=$(ls /run/udev/data 2>/dev/null | grep -c '^n') $(date +%T)"
    # 09-24 实锤：kill 段的 `systemctl stop wpa_supplicant` 之后，NM 1.54 有时整个会话
    # 都不发起 fi.w1.wpa_supplicant1 的 D-Bus 激活（journal 零激活请求，wlan0 永久
    # unavailable，桌面里搜不到任何热点）。不再赌它的懒激活：起 NM 前先把 supplicant 拉活。
    # 10:47 轮教训：systemd 管的 supplicant（Type=dbus + Group=netdev 降权）进程不可
    # dumpable，strace attach 一律 EPERM，wpa 侧连续两轮 0 字节=盲区。改为自拉 nohup
    # 版（同 root，可 attach），-t 时间戳日志落文件。
    stop_supplicant                       # 上一轮残留：先 TERM 等它自己注销 cfg80211 请求
    # 失败轮的**真签名**（09-25 09:41 / 10:20 两轮）是 supplicant 每 10s 重试都报
    #   Could not set interface wlan0 flags (UP): Invalid argument
    #   WEXT: Could not set interface 'wlan0' UP → wlan0: Failed to initialize driver interface
    # 也就是**内核拒绝把 wlan0 拉 UP**；而"是谁拒的"当时没采到 ⇒ 起 supplicant 前一次采全：
    # rfkill 软/硬阻塞、全部 wdev（看有没有上一任的残骸）、接口 flags、驱动是否在做 recovery。
    # 只采状态、不下判断（避免"OK"打在没验证的对象上，见工作总结的探针自证纪律）。
    {
        echo "WIFI-PRESTATE $(date +%T) uptime=$(cut -d. -f1 /proc/uptime)s"
        # 容器 /dev 里没有 /dev/rfkill（同 /dev/uhid 那类缺件，见 5.29②），所以走 sysfs；
        # 读不到就明着打 READ-FAIL —— 权限盲区比"没有阻塞"更危险，不能让它伪装成后者。
        # **判阻塞以 soft/hard 为准，别信 state**：本机实测 wlan 那份 `soft=0 hard=0` 却
        # `state=1`（安卓侧 WiFi 正在连接中，显然没被阻塞）—— 与 power-state-sync 那条
        # "小米 BSP 的 current_now 符号反了"同族的口径坑。
        for r in /sys/class/rfkill/rfkill*; do
            [ -e "$r/soft" ] || continue
            so=$(cat "$r/soft" 2>/dev/null) || so=READ-FAIL
            ha=$(cat "$r/hard" 2>/dev/null) || ha=READ-FAIL
            st=$(cat "$r/state" 2>/dev/null) || st=READ-FAIL
            echo "  $(basename $r) type=$(cat $r/type 2>/dev/null) name=$(cat $r/name 2>/dev/null) soft=$so hard=$ha (state=$st，仅参考)"
        done
        echo "  --- wdev 一览（看有没有上一任留下的残骸 iface）---"
        iw dev 2>&1 | grep -E "phy|Interface|ifindex|wdev|type" | head -30
        ip -o -br link show wlan0 2>&1
        # 驱动 recovery 状态**必须走安卓侧 dmesg**：容器的 dmesg 里 cnss/wlan 一条都没有
        # （实测 15590 行里 0 命中），安卓侧 root 读才有（同刻实测 4 命中，含 cnss-daemon 行）。
        run "dmesg | grep -icE \"cnss|is_driver_recovering|subsys.*(restart|crash|fatal)\""
        run "dmesg | grep -iE \"cnss|is_driver_recovering|wlan0\" | tail -8"
    } 2>&1 | tee $LOGD/wifi-prestate.txt
    iw dev wlan0 scan abort >/dev/null 2>&1
    # 【09-25 傍晚】原来的 PRECLEAR down;sleep 1;up 就是 5.36 定案的致命动作本身（探针不能拿
    # 命换信息）⇒ 改只读。此刻若已 DOWN，up 的路径归射频状态机（安卓 toggle / supplicant
    # 自带 up），我们不替它做 ⇒ 置 WIFI_SKIP 走"无网桌面"分支（desk-stop 照常交还）。
    # ⚠ UP 判定必须解析 flags 尖括号（16:29 轮实锤的自身 bug：`ip -o -br link` 输出
    # "wlan0 DOWN ... <NO-CARRIER,BROADCAST,MULTICAST,UP>"，operstate 列是 DOWN 但 IFF_UP
    # 在 flags 里；`grep ' UP'` 要求空格前缀永远不命中 ⇒ 把 admin-UP 误判成 DOWN，
    # 白跳过整段 WiFi。探针错一次，结论全反——先自证探针会命中再信它的否定）。
    LRAW=$(ip -o link show wlan0 2>/dev/null | head -1)
    LFLAGS=$(echo "$LRAW" | sed -n 's/.*<\([^>]*\)>.*/,\1,/p')
    if [ -z "$LFLAGS" ]; then
        echo "WIFI-SKIP(admin-probe-fail) $(date +%T)：flags 提取失败，raw=[$LRAW]——按非 UP 处理并点名探针"
        WIFI_SKIP=1
    else
        case "$LFLAGS" in
            *,UP,*)
                echo "WIFI-ADMIN UP（不 flap，只做 L3 清理） $(date +%T) flags=${LFLAGS//,/ }"
                ;;
            *)
                echo "WIFI-SKIP(admin-down) $(date +%T)：wlan0 flags=$LFLAGS 无 UP，禁 flap 红线生效，本轮跳过 WiFi 段"
                WIFI_SKIP=1
                ;;
        esac
    fi
    if [ "$WIFI_SKIP" = 1 ]; then
        :
    else
    mkdir -p /run/wpa_supplicant
    nohup /usr/sbin/wpa_supplicant -u -t -O "DIR=/run/wpa_supplicant GROUP=netdev" \
        > $LOGD/wpa-drm.log 2>&1 &
    echo $! > /run/desk-wpa.pid   # desk-stop 按 PID 精确杀（cmdline 无 desk-wifi，模式杀不到）
    echo "WPA_PID=$! $(date +%T)"
    sleep 1
    # 09-24 10:22 轮教训：--log-domains 是白名单；10:39 轮教训：--log-level 命令行无效
    # → 日志级别全部走 /run/nm-drm.conf 的 [logging] 段。
    nohup NetworkManager --config /run/nm-drm.conf --no-daemon \
        > $LOGD/nm-drm.log 2>&1 &
    NMPID=$!
    echo "NM_PID=$NMPID $(date +%T)"
    # 同轮双 strace：wpa 侧 10:39 轮抓到的量=0（=NM 压根没对 supplicant 发过 dbus 调用，
    # 这是重要负证据）→ 这轮从 NM 侧看它到底发了什么/为什么不发。
    WPAPID=$(pgrep -x wpa_supplicant | head -1)
    [ -n "$WPAPID" ] && nohup strace -f -tt -s 400 -e trace=network -p "$WPAPID" \
        -o $LOGD/wpa-strace.txt >/dev/null 2>&1 &
    nohup strace -f -tt -s 400 -e trace=network -p "$NMPID" \
        -o $LOGD/nm-strace.txt >/dev/null 2>&1 &
    for i in $(seq 1 15); do nmcli status >/dev/null 2>&1 && break; sleep 1; done
    nmcli radio wifi on 2>/dev/null   # 清掉可能的软阻塞（上一轮残留状态）
    # p2p0（Wi-Fi Direct 虚拟口）配置语法排除不了（见 /run/nm-drm.conf 注释）→
    # 走 run-state。它由 supplicant P2P 初始化时慢建，NM 重启也会重置该标记，
    # 所以后台带重试收敛，不阻塞主流程。
    (
        for i in $(seq 1 20); do
            sleep 3
            nmcli dev set p2p0 managed no 2>/dev/null && break
        done
    ) &
    # 首轮引导：NM 刚起扫描缓存是空的，先 rescan 再带重试连接；
    # 成功即自动落 keyfile(0600)，以后自连、plasma-nm 面板可改
    if [ -n "$CUR_SSID" ] && [ -n "$CUR_PSK" ]; then
        (
            # 子 shell 继承 xtrace，nmcli connect 展开后的 password 会进日志（09-24 泄漏实锤）
            set +x
            for t in 1 2 3 4 5; do
                sleep 3
                # 09-24 12:21 轮：连上后循环仍又跑了几次（profile 名匹配不总是及时）→
                # 直接以 wlan0 状态收口，防重入 rescan/connect 抖动已建好的链路
                LC_ALL=C nmcli -t -f DEVICE,STATE device 2>/dev/null | grep -q '^wlan0:connected' && break
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
        [ "$(LC_ALL=C nmcli -t -f DEVICE,STATE device 2>/dev/null | grep '^wlan0:' | cut -d: -f2)" = "connected" ] && { OK=1; break; }
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
        # 10:39 轮：REASON 不是本版本 device 表的合法字段。StateReason 走 D-Bus 属性。
        LC_ALL=C nmcli -t -f DEVICE,TYPE,STATE device 2>&1 | grep -vE '^(lo|dummy|p2p)' | head -8
        WP=$(nmcli -t -f DEVICE,DBUS-PATH device 2>/dev/null | awk -F: '/^wlan0:/{print $2}')
        echo "wlan0 dbus path: $WP"
        busctl get-property org.freedesktop.NetworkManager "$WP" org.freedesktop.NetworkManager.Device StateReason 2>&1
        busctl introspect org.freedesktop.NetworkManager "$WP" 2>/dev/null | grep -cE "Wireless|Supplicant" 
        gdbus call --system --dest fi.w1.wpa_supplicant1 --object-path /fi/w1/wpa_supplicant1 --method org.freedesktop.DBus.Properties.Get fi.w1.wpa_supplicant1 Interfaces 2>&1 | head -c 300; echo " <-supplicant Interfaces"
        echo "--- polkit health (重启等待是否生效、NM 权限查询通不通) ---"
        systemctl is-active polkit 2>&1
        timeout 5 nmcli general permissions 2>&1 | head -6
        tail -n 20 $LOGD/wpa-drm.log 2>/dev/null
        tail -n 60 $LOGD/nm-drm.log
        echo "NET-FAILED (NM) $(date +%T): desktop kept, NO network"
    fi
    fi   # WIFI_SKIP 分流收尾（起 supplicant/NM 的 else 支路到此为止）
else
# ---- 5L) legacy 手管段（NM 未安装时的 fallback，原 wpa+dhcpcd+表1015 方案） ----
if [ -f "$WIFI_GEN" ] || [ -f "$WIFI_CONF" ]; then
[ -f "$WIFI_GEN" ] && WIFI_CONF="$WIFI_GEN"
pkill -TERM -x wpa_supplicant 2>/dev/null   # legacy 段本就只在容器内跑；-x 命中容器实例
pkill -x dhcpcd 2>/dev/null
sleep 1
# 5.36 禁 flap 红线同样适用于本 fallback 段（只读确认，不 down/up；非 UP 就让 wpa 自己失败
# 走 NET-FAILED 支路，桌面照留，交还不冻结 rtnl）
ip -o -br link show wlan0 2>/dev/null
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
    pkill -TERM -x wpa_supplicant 2>/dev/null
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

# ---- 5c) 蓝牙：容器侧 BlueZ 直接吃安卓的蓝牙 HAL（见 droid-bluetooth-bridge 仓库）----
# 链路 09-24 实测通了：桥 initialize(oneway,码2) → HAL 自己开 ttyHS0/glink →
# 桥用 pty+N_HCI 在共享内核里注册真 hci0 并双向搬运 HCI（裸包，不带 H4 类型字节）→
# 容器 bluetoothctl 看到 Controller（UP RUNNING、真 BD_ADDR、扫到周围设备）。
# **默认开**（`BT_BRIDGE=0` 可关）。09-25 实测：裸 udevd + 桥同轮跑，WiFi 全程正常
# （ping 通、dmesg 里 `is_driver_recovering` 计数 0），蓝牙鼠标连上可用；
# 之前"默认开就炸 WiFi"是错的归因，真凶是**同轮里 restart 服务化 udevd**（见 5.31）。
# 桥本身只走 BT 的 glink/ttyHS，绝不下固件、绝不碰 btpower ioctl。
# 轮内蓝牙与 WiFi 同政策：**默认开 + 用户关不掉**。落点不同（蓝牙侧没有 polkit 可用）：
# 5c 尾装一条 dbus 总线策略拒桌面用户写适配器属性（每轮实测它在不在），掉电兜底与桥卡死
# 自愈交给 scripts/bt-keepalive.sh。
# 三道护栏（都是被实测逼出来的，缺一不可）：
#   ① 桥自熔断：每 10s 查 init.svc.surfaceflinger，一旦 running 就自退
#      （曾抓到 surfaceflinger=running 时桥还活着 = 安卓蓝牙栈与我们同时持有 HAL 客户端位）；
#   ② desk-stop 的 kill_desktop 与 50s 看门狗都杀桥（**必须走 run 到安卓侧**：桥在安卓 PID ns，
#      容器侧 pgrep 看不见它，09-30 之前那两行容器侧 pkill 一直是空操作 = 假护栏）；
#   ③ desk-takeover 的 rollback 分支也杀（KDE 重启/回滚都不走 desk-stop）。
# 交还时 desk-stop 先杀桥：进程一退 tty 就关 → 内核自动注销 hci0。
# 匹配一律 `pgrep bthci-bridge`（按 comm）：-x 会漏掉改名的桥，-f 会自匹配 su -c 的壳，见 bridge_pids()
if [ "${BT_BRIDGE:-1}" = 1 ]; then
BTBIN=${BT_BIN:-/data/local/tmp/bthci-bridge-v2}
echo "BT-BIN $BTBIN $(date +%T)（v2 已实测一轮：转发 240 命令、内核侧 errors=0、鼠标 96% 电量在线、在途命令=[无]、写pty 全 full 无丢包；退回旧构建用 BT_BIN=/data/local/tmp/bthci-bridge）"
# 桥的 kickHci 是"借容器 bluetoothd 的 ns 跑 hciconfig hci0 up"，bluetoothd 不在就没内核侧 init
systemctl start bluetooth 2>/dev/null
# 【开局遇到 bt_power soft=1 怎么办：等，不是跳过】09-30 实测两遍，第二遍把我的"定案"推翻了：
# `rfkill name=bt_power soft=1`（伴随 persist.vendor.bluetooth.state=0）是**接管开局的暂态**，
# 芯片电源由 vendor HAL/btpower 协调，它自己会回 0；一回 0，**同一个没被重拉过的桥**立刻就通
# （00:52:15 还卡在 `转发=50 收回=50 回调=51` → 00:54:54 soft 归 0 → root power on 一次 →
#  `Powered: yes`、同一进程计数走到 `转发=152`）。
# 所以这里照常拉起桥、照常判定，只是把"电源还没到"这件事**如实标注**，并交给看门狗补最后一步
# （它看到 soft 归 0 会自动 power on）。曾经写成"soft=1 就跳过桥"，那样本轮蓝牙永远不会可用——
# 是用户的实测（"我试了下现在打开蓝牙能用啊"）把这条纠正回来的。
BTOFF=0
for r in /sys/class/rfkill/rfkill*; do
    [ "$(cat $r/type 2>/dev/null)" = bluetooth ] || continue
    [ "$(cat $r/name 2>/dev/null)" = bt_power ] || continue
    [ "$(cat $r/soft 2>/dev/null)" = 1 ] && BTOFF=1
done
if [ "$BTOFF" = 1 ]; then
    echo "BT-POWER-PENDING $(date +%T): $(ls /sys/class/rfkill | while read x; do [ "$(cat /sys/class/rfkill/$x/name 2>/dev/null)" = bt_power ] && echo $x; done | tr '\n' ' ')(bt_power) soft=1，persist.vendor.bluetooth.state=$(run "getprop persist.vendor.bluetooth.state" | tr -d '\r' | tail -1) ⇒ 芯片电源还没到（开局暂态）。照拉桥，上电这一步交给看门狗在 soft 归 0 后自动补"
fi
# `</dev/null`：detached 进程别占着 adb 的 pty。注意历史上这行每次吃满 12s 超时
# （logs/desk-takeover.log 里 RUN-TIMEOUT 118 条全是它），但实测单独 launch 一个 detached
# sleep 只花 0.1s ⇒ 超时真因未定，别把加这行说成"修好了超时"，它只是卫生写法。
run "test -x $BTBIN || echo BT-NO-BIN; pgrep bthci-bridge || nohup $BTBIN --keep 0 </dev/null >>/data/local/tmp/bt-bridge.log 2>&1 &"
# 开局就要确认"只有一个桥"：两个桥 = 两个 HAL 客户端抢同一颗芯片（§63 那个卡死就是这么来的）
sleep 2
BPIDS=$(bridge_pids)
BCOUNT=$(printf '%s\n' "$BPIDS" | grep -c '^[0-9]')
if [ "$BCOUNT" != 1 ]; then
    echo "BT-BRIDGE MULTI $(date +%T): 进程数=$BCOUNT pids=$(echo $BPIDS | tr '\n' ' ') ⇒ 本轮蓝牙不可信（多半是上一个交还轮的桥没被杀掉），先 desk-stop 再重跑"
fi
[ "$BCOUNT" = 1 ] && echo "BT-BRIDGE ONLY $(date +%T): pid=$BPIDS name=$(run "cat /proc/$BPIDS/comm" | tr -d '\r' | tail -1)"
# 判据要重试：桥的 initialize→initializationComplete→内核 init 60 命令→bluetoothd 认领
# 整串要在 WiFi 关联同窗口排队，+8s 单发经常赶不上（16:59 轮实测：报 FAIL 时桥其实活着，
# bt-bridge.log 里 hciEventReceived 一直有——FAIL 是判据太早，不是功能坏）。
BTCUP=0
for i in 1 2 3; do
    sleep 8
    if bluetoothctl list 2>/dev/null | grep -q "^Controller"; then BTCUP=1; break; fi
done
run "tail -n 2 /data/local/tmp/bt-bridge.log 2>/dev/null"
if [ "$BTCUP" = 1 ]; then
    # 名字：E:Name 来自芯片自己的 Read_Local_Name（这台是主机名 Ubuntu），列表里像陌生机器；
    # BlueZ 对外广播/展示用 Alias，这里钉成稳定可认的名字（改不动 Name）。
    bluetoothctl system-alias "Piano BT" >/dev/null 2>&1
    # 【默认开】09-29 实锤：bluetoothd 自己起时芯片还没 hci0，后来挂上来的适配器不保证是
    # 上电态（当时 bluetoothctl show = Powered: no / PowerState: on，桌面里就是"打不开"）。
    # 所以判过 Controller 存在之后必须显式要一次上电，并按实测结果报，不拿"进程在跑"当"能用"。
    # 上电重试放宽到 6 次×5s（≈30s）：芯片电源是开局暂态，多等一会儿常常就自己通了
    BTPOW=0
    for i in 1 2 3 4 5 6; do
        bluetoothctl power on >/dev/null 2>&1
        sleep 5
        bluetoothctl show 2>/dev/null | grep -q 'Powered: yes' && { BTPOW=1; break; }
    done
    if [ "$BTPOW" = 1 ]; then
        echo "BT-POWER OK $(date +%T): Powered: yes（第 $i 次）"
        # 【显示修正·必做】class 级 rfkill 只要有一颗 type=bluetooth 是 soft-blocked，
        # bluedevil 的托盘/设置页就显示"蓝牙已禁用"（它看的是 BluezQt::isBluetoothBlocked，
        # 不是 Adapter1.Powered），而鼠标照连 —— 功能和显示分家。本机那颗是 vendor 的
        # `bt_power`（接管轮里常年 soft=1）。用户平时的"手动开一下开关"其实就是解这个阻塞，
        # 这里自动做掉。写的是 /dev/rfkill 的标准 RFKILL_OP_CHANGE，**不是** btpower 电源 ioctl
        # （§蓝牙红线禁的是后者）；实测做完 `soft 1→0`，桥与已连接鼠标都不掉。
        bash $DIR/scripts/bt-rfkill-unblock.sh || echo "BT-UNBLOCK FAIL $(date +%T): 没解成，托盘可能仍显示已禁用"
        # 兜底：万一 applet 没响应 bluetoothBlockedChanged（旧版本/异常），可手动重载壳。
        # 默认**不**自动重载 —— 那会让面板闪没一下，而且现在已知真正的原因是 rfkill 阻塞。
        if [ "${BT_UI_REFRESH:-0}" = 1 ]; then
            start_plasmashell
            sleep 3
            PMPID=$(pgrep -x plasmashell | head -1)
            if [ -n "$PMPID" ] && grep -qc "plasma.bluetooth" /proc/$PMPID/maps 2>/dev/null; then
                echo "BT-UI-REFRESH OK $(date +%T): plasmashell pid=$PMPID 已载入蓝牙 applet"
            else
                echo "BT-UI-REFRESH FAIL $(date +%T): pid=${PMPID:-没起来} 里看不到 org.kde.plasma.bluetooth（看 $LOGD/plasma.log）"
            fi
        fi
    else
        echo "BT-POWER FAIL $(date +%T): 6 次 power on 后仍不是 Powered: yes —— $(bluetoothctl show 2>/dev/null | grep -E 'Powered|PowerState' | tr '\n' ' ') bt_power.soft=$( { for x in /sys/class/rfkill/rfkill*; do [ "$(cat $x/name 2>/dev/null)" = bt_power ] && cat $x/soft; done; } ) ⇒ 交给看门狗：它在 soft 归 0 后自动补 power on，不会重拉桥"
    fi
    echo "BT-NATIVE OK $(date +%T): $(bluetoothctl list | head -1)"
    echo "  配对要先让对方发现你：bluetoothctl discoverable on（默认 180s 超时，不默认开）"
else
    echo "BT-NATIVE FAIL $(date +%T): 容器里看不到 Controller（查 $BTBIN 是否活、bluetoothd、bt-bridge.log）"
fi

# 【不可关闭·策略层】09-29 深夜三轮对照实验（同一 uid 1000、同一条命令）把方向钉死了：
#   · 容器**原生状态下普通用户写适配器属性是成功的**（`method return`）⇒ 桌面本来能把蓝牙关掉；
#   · 装上下面这条 scoped deny → 同一写操作回 `AccessDenied: Rejected send message, 3 matched rules`；
#   · 再删掉文件 → 又恢复成功。
#   注：全程没执行 ReloadConfig 也照样生效（dbus 自己读到了 system.d 的变化），但这里仍显式
#   Reload 一次，不靠"碰巧"。（我一度把"装了文件后被拒"错读成"包自带规则早就在拒"，方向正好
#   反了一次 —— 复盘见 工作总结 §58。）
# 作用域也是实测的：只拦 `/org/bluez/hci0`（适配器）上的 `Properties.Set`；
#   设备对象上用不存在的属性名做一次写 → 回的是 bluez 的 `UnknownProperty`（=总线放行）
#   ⇒ 扫描/配对/连鼠标/Trusted 不受影响；`Get` 照常放行，UI 读状态不会卡。
# WiFi 那边的 polkit NO 在蓝牙上没有对应物：bluetoothd 不接 polkit（NEEDED 只有
# libdbus/libglib/libudev/libasound/libdw/libc），能落地的层次就是总线策略。
# 文件持久在容器 rootfs 的 /etc 里 ⇒ desk-stop 必须删，否则"关不掉"会泄漏到轮外。
if [ "${BT_BRIDGE:-1}" = 1 ]; then
    cat > /etc/dbus-1/system.d/61-bluez-drm-lock.conf <<'EOF'
<!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-BUS Bus Configuration 1.0//EN"
 "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
<busconfig>
  <!-- DRM 接管轮：蓝牙总开关对桌面用户拒动（Powered 只能由 root/看门狗决定）。
       属性写只发生在 /org/bluez/hci0（适配器）上；设备对象(/org/bluez/hci0/dev_*)不拦，
       所以扫描、配对、连鼠标这些照常。 -->
  <policy user="__DRM_USER__">
    <deny send_destination="org.bluez" send_path="/org/bluez/hci0"
          send_interface="org.freedesktop.DBus.Properties" send_member="Set"/>
  </policy>
</busconfig>
EOF
# 占位符替换：策略文件内容必须是确定的用户名（heredoc 用引号包住，避免任何 shell 展开跑进策略里）
sed -i "s/__DRM_USER__/$DRM_USER/g" /etc/polkit-1/rules.d/61-powerdevil-backlight.rules \
    /etc/polkit-1/rules.d/60-nm-drm.rules /etc/dbus-1/system.d/61-bluez-drm-lock.conf 2>/dev/null
    # 重启 system bus 会连带打断 NM/kded，所以只 ReloadConfig。
    dbus-send --system --dest=org.freedesktop.DBus /org/freedesktop/DBus \
        org.freedesktop.DBus.ReloadConfig >/dev/null 2>&1 \
        || echo "BT-LOCK NOTE $(date +%T): ReloadConfig 没应答（实测不靠它也生效，继续自检）"
    # 自检必须自证会被触发：以桌面用户身份做一次**幂等**的属性写（Alias 写回当前值，零副作用），
    # 期望被拒；没被拒就明报 BT-LOCK MISSING —— 不拿"装了文件"冒充"锁上了"。
    # 没有 Controller 时这条路径走不到（回 UnknownObject，那是"没测到"不是"没锁"），单独 SKIP。
    if bluetoothctl list 2>/dev/null | grep -q "^Controller"; then
        CURALIAS=$(bluetoothctl show 2>/dev/null | awk '/^\tAlias:/{print $2}')
        LOCKCHK=$(runuser -u "$DRM_USER" -- dbus-send --system --dest=org.bluez --print-reply \
            /org/bluez/hci0 org.freedesktop.DBus.Properties.Set \
            string:org.bluez.Adapter1 string:Alias variant:string:"${CURALIAS:-Piano BT}" 2>&1)
        if echo "$LOCKCHK" | grep -q "AccessDenied"; then
            echo "BT-LOCK OK $(date +%T): 桌面用户写适配器属性被总线拒（蓝牙总开关点不动；root 与看门狗照常能动）"
        else
            echo "BT-LOCK MISSING $(date +%T): 写了策略文件但属性写**没被拒** ⇒ 桌面仍能关蓝牙，只剩下面的看门狗兜底。返回：$(echo "$LOCKCHK" | tr '\n' ' ' | head -c 160)"
        fi
    else
        echo "BT-LOCK SKIP $(date +%T): 容器里没有 Controller，锁的实测留到看门狗的 NOT-POWERED 证据行"
    fi
    # 【兜底 + 自愈】看门狗 scripts/bt-keepalive.sh（root，轮内常驻）：
    #   · 芯片电源被安卓侧关着（bt_power soft=1）→ 只报 BT-CHIP-BLOCKED，**不重拉**（实测白拉 17 次）；
    #   · 真掉电 → power on 回开（策略层只挡普通用户，root/CLI/rfkill 这条路归它兜）；
    #   · 卡死三级台阶：内核 hciconfig up 重踢 → 重拉桥（先杀旧再拉新，整轮上限 2 次）→
    #     到顶 BT-GIVEUP 收手并 dump logs/bt-wedge-*.txt 现场。猛拉 HAL 客户端是有害的，见脚本头注。
    # 它自带 surfaceflinger 熔断（交还即自退），desk-stop 与 rollback 还各杀一次，三重。
    pkill -f "bt-keepalive[.]sh" 2>/dev/null
    SNAP_DIR=$LOGD BT_BIN=$BTBIN nohup bash $DIR/scripts/bt-keepalive.sh >> $LOGD/bt-keepalive.log 2>&1 &
    KAPID=$!
    sleep 1
    # 判据必须打在它声称的那个对象上：`pgrep -f bt-keepalive.sh` 会匹配到**所有**同名实例
    # （09-30 实测安卓侧确实并存过两个看门狗 = 两套重拉节奏叠着打同一个 HAL），head -1 报的
    # 未必是本实例。直接取自己后台任务的 $!，再验它活着且 cmdline 对得上。
    if kill -0 "$KAPID" 2>/dev/null && tr '\0' ' ' < /proc/$KAPID/cmdline 2>/dev/null | grep -q "bt-keepalive.sh"; then
        echo "BT-KEEPALIVE OK $(date +%T): pid=$KAPID 日志 $LOGD/bt-keepalive.log"
    else
        echo "BT-KEEPALIVE FAIL $(date +%T): pid=$KAPID 不在或 cmdline 不是 bt-keepalive.sh（查 $LOGD/bt-keepalive.log）"
    fi
fi
else
    echo "BT-BRIDGE SKIPPED $(date +%T)（本轮 /run/drm-round.conf 或环境变量里显式 BT_BRIDGE=0）"
fi

# ---- 5f) A 路容器侧喂流器（桌面/PipeWire 起来之后才拉，抓默认 sink 的 monitor）----
# 与 §2b 的安卓侧 halsink 配套：feeder 把 anland PipeWire 的声音 s16/48k 推到 127.0.0.1:44777，
# 安卓侧 argsloop 转 s32 喂进 HAL。共享 netns ⇒ 环回可达。非关键：缺脚本/起不来只报，不回滚。
if [ "${AUDIO_BRIDGE:-0}" = 1 ] && [ "${AUDIO_ROUTE:-a}" = a ]; then
  FEEDER=$DIR/scripts/aa-feeder.sh
  if [ ! -f "$FEEDER" ]; then
    echo "AUDIO-FEEDER SKIP $(date +%T)：没有 $FEEDER"
  else
    pgrep -f "aa-feeder.sh" >/dev/null 2>&1 || \
      runuser -u "$DRM_USER" -- env HOME="$DRM_HOME" XDG_RUNTIME_DIR=$DRM_RT \
        nohup sh "$FEEDER" 127.0.0.1:44777 >>"$LOGD/hal-feeder.log" 2>&1 &
    sleep 2
    if pgrep -f "aa-feeder.sh" >/dev/null 2>&1; then
      echo "AUDIO-FEEDER OK $(date +%T)：容器 monitor → 127.0.0.1:44777（日志 $LOGD/hal-feeder.log）"
      echo "  安卓侧 sink 判据：adb shell su -c 'grep -a \"SINK t=\" /data/local/tmp/hal-sink.log | tail'"
    else
      echo "AUDIO-FEEDER FAIL $(date +%T)：feeder 没起来（查 PipeWire/默认 sink、$LOGD/hal-feeder.log）"
    fi
  fi
fi

# ---- 5g) 音量键第二次机会（10-02）：kded6 起跑时常加载不上 audioshortcutsservice
# （loadModule 回 true 但 maps 0 命中；anland 的 kded6 反而总有——它起跑时 PipeWire/会话
# 早已就绪，轮内 kded6 起跑时音频系统多半还没热）。4b' 窗口期未映射就到这里重发一次
# loadModule，再给 60s maps 轮询；成不成都在日志落一行，判据永远看 maps 不看返回值。
if [ "${AUDIOKEY_PENDING:-0}" = 1 ] && [ -n "$KDPID" ] && [ -d /proc/$KDPID ]; then
    XDG_RUNTIME_DIR=$DRM_RT DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$DRM_UID/bus \
        runuser -u "$DRM_USER" -- busctl --user call org.kde.kded6 /kded org.kde.kded6 \
        loadModule s audioshortcutsservice >/dev/null 2>&1
    AHITS2=0
    for _ak in $(seq 1 30); do
        AHITS2=$(grep -c "audioshortcutsservice" /proc/$KDPID/maps 2>/dev/null)
        AHITS2=${AHITS2:-0}
        [ "$AHITS2" -gt 0 ] && break
        sleep 2
    done
    KMIX=$(XDG_RUNTIME_DIR=$DRM_RT DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$DRM_UID/bus \
        runuser -u "$DRM_USER" -- busctl --user get-property org.kde.kglobalaccel \
        /component/kmix org.kde.kglobalaccel.Component shortcutNames 2>/dev/null)
    if [ "$AHITS2" -gt 0 ]; then
        echo "AUDIOKEY-RETRY OK audioshortcutsservice 已映射进 kded(pid=$KDPID)（maps $AHITS2 条，kmix 快捷键${KMIX:+已注册}）$(date +%T)"
    else
        echo "AUDIOKEY-RETRY FAIL $(date +%T): 音频就绪后重发 loadModule 仍未映射（kmix 组件=${KMIX:-无响应}）⇒ 音量键无效；下一轮取证 busctl --user tree org.kde.kded6"
    fi
fi
if [ "${AUDIO_BRIDGE:-0}" != 1 ]; then
    # 明着写一行，免得以后把"轮内没声音"当成故障去查（09-30 起默认关，原因见 §2b 头注）
    echo "AUDIO-SPEAKER OFF $(date +%T)：A 路外放默认关闭（与蓝牙 A2DP 抢同一套输出路由）；要外放：echo 'AUDIO_BRIDGE=1' > /run/drm-round.conf 后重跑一轮"
fi

# ---- 6) 收尾：取证收割机 + 状态 ----
# pref0 终态计数：轮内再漂移的话，$LOGD/ip-rule-monitor.log 里会留着 re-adder 现场
echo "IPRULE-FINAL pref0=$(ip -o rule show | grep -c '^0:') total=$(ip -o rule show | wc -l) $(date +%T)"
DEV=$DEV nohup bash $DIR/scripts/dmesg-harvester.sh > /dev/null 2>&1 &
adb -s "$DEV" shell "su -c 'free -m | head -2'"
if [ -z "$PSHELL" ]; then
    echo "=== DESK-TAKEOVER DONE $(date +%T): kwin pid $KPID, **PLASMA 没起来=黑屏**（见上面 PLASMA-FAIL） ==="
else
    echo "=== DESK-TAKEOVER DONE $(date +%T): kwin pid $KPID, plasmashell pid $PSHELL ==="
fi
