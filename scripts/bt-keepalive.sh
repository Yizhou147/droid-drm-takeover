#!/bin/bash
# bt-keepalive.sh — 接管轮内的蓝牙守门人：保证"默认开 + 关不掉"，并在 HCI 通道卡死时按
# 最小代价恢复；恢复不了就**收手并留现场**，不再反复重拉。
#
# 为什么不是"掉电就重拉桥"（09-30 首跑被实测打脸，写死在这儿）：
#   那一轮 6 分钟内 4 次重拉、到我接手时已 17 次，每次新 attach 都能 initializationComplete(SUCCESS)，
#   但 30~90s 内又死；最后一次的签名是 `转发=50 收回=50 回调=51` **三个计数一起冻住**
#   （09-29 那次的签名是"收回暴涨到 4.8 万、转发冻在 520"的单向死）。
#   ⇒ 重拉没治好，反而每轮多造一个 HAL 客户端；日志里早有
#     `DataHandler::Open: Returning as protocol already added` + `INITIALIZATION_ERROR`
#     ——HAL 被残留/多个客户端占着的签名。**猛拉是有害的**，所以下面是"三级台阶 + 上限 + 收手"。
#
# ★ 一条把设计打穿过的实测事实：**桥跑在安卓的 PID ns 里，容器侧 pgrep 看不见它**
#   （同一时刻安卓侧 pid=23637，容器侧 `pgrep -x bthci-bridge` 为空）。
#   所以桥的存活/计数一律经 adb 问安卓侧；任何"本地 pgrep 说桥死了"都不能当证据。
# ★ 两条探针陷阱（09-30 都栽过，写死）：
#   · `/sys/class/bluetooth/hci0/{address,flags}` 在本机**不存在**（root 读也 No such file）
#     ⇒ "address 读不到"完全不能当卡死签名；要看 `hciconfig hci0` 的 flags
#     （`DOWN` vs `UP RUNNING`）与 TX `commands/errors`——那才是内核侧真实状态；
#   · 桥日志已 500MB+，计数**必须 `tail -n` 按行取**：`tail -c` 会切出半行让 sed 落空，
#     显示成 `NOREAD`——那是探针自己坏了，不是"通道冻结"。上一版据此误判过。
#
# 三级台阶（判据以桥自己的计数为准——那是 HCI 通道的地表事实，bluetoothd 的 Powered 只是下游表象）：
#   ① `hciconfig hci0 up`：内核侧重踢，零成本（桥 setup 时自己也是这么干的）
#   ② 仍不行才重拉桥，整轮最多 RESTART_MAX 次
#   ③ 到顶就 BT-GIVEUP：不再动任何东西，dump 一份现场到 <项目根>/logs/bt-wedge-*.txt
#   宽限期：启动后与每次重拉后 GRACE 秒内不判定（attach/注册 hci0 本来就有空窗，
#   拿它当卡死 = 自己造抖动，上一版就栽在这儿）
#
# 常态职责：
#   · 熔断（红线）：init.svc.surfaceflinger=running ⇒ 立刻自退，把 HAL 客户端位还给安卓；
#   · 保活：Powered 不是 yes 就先 `bluetoothctl power on`（root 侧；策略层只挡得住普通用户）。
# 本进程只做蓝牙侧动作：不碰 rfkill ioctl、不碰 ttyHS0/btpower、不重启任何服务。
# 单实例闸门：两个看门狗并存 = 两套重拉节奏叠着打同一个 HAL（09-30 实测安卓侧确实并存过）。
# 不用 `ps | grep 自己的脚本名`：`$(...)` 会 fork 出一个 cmdline 与父进程完全相同的子 shell，
# 于是"自己"被数成第二个实例，两个实例双双秒退（09-30 实测踩过）。改 pid 锁文件，判定确定性。
LOCK=${BT_LOCK:-/run/bt-keepalive.pid}
OLD=$(cat "$LOCK" 2>/dev/null)
if [ -n "$OLD" ] && kill -0 "$OLD" 2>/dev/null \
   && tr '\0' ' ' < /proc/"$OLD"/cmdline 2>/dev/null | grep -q "bt-keepalive.sh"; then
    echo "BT-KEEPALIVE DUP $(date +%T): 已有实例 pid=$OLD 在跑 ⇒ 本实例退出"
    exit 0
fi
echo $$ > "$LOCK"
cleanup() { [ "$(cat "$LOCK" 2>/dev/null)" = "$$" ] && rm -f "$LOCK"; }
trap cleanup EXIT
DEV=$(adb devices | awk '$2=="device"{print $1; exit}')
[ -n "$DEV" ] || { echo "BT-KEEPALIVE EXIT $(date +%T): 没有 adb 设备，无法观测安卓侧状态"; exit 0; }
BTBIN=${BTBIN:-${BT_BIN:-/data/local/tmp/bthci-bridge}}   # BT_BIN 可指向 -v2，用于灰度新二进制
BTLOG=${BTLOG:-/data/local/tmp/bt-bridge.log}
# 现场目录与接管轮日志同处 = <项目根>/logs（本脚本在 <项目根>/droid-drm-takeover/scripts/）
SNAPD=${SNAP_DIR:-$(dirname "$(dirname "$(dirname "$(readlink -f "$0")")")")/logs}
INTERVAL=${INTERVAL:-10}
GRACE=${GRACE:-45}          # 启动/重拉后的宽限期（秒）
RESTART_MAX=${RESTART_MAX:-2}
POWFAIL_MAX=${POWFAIL_MAX:-2}
PREV=""                     # 上一轮采到的计数（快照里当证据用）
PREV_FWD=""
FWD_FROZEN=0                # 转发计数连续几轮没动
FAILS=0                     # power on 连轮要不来
RESTARTS=0
KICKED=""                   # 每段只踢一次内核，别刷
GAVEUP=""
NEXT_JUDGE=0                # 早于这个 epoch 秒不判定（宽限期）
CB_LAST=0                   # 上次报 BT-CHIP-BLOCKED 的时刻（同状态 5 分钟只报一次，防刷日志）

run() {
    local out rc
    out=$(timeout 8 adb -s "$DEV" shell "su -c '$1'" 2>&1); rc=$?
    [ $rc -eq 124 ] && echo "BT-KEEPALIVE RUN-TIMEOUT(8s): $1"
    printf '%s\n' "$out"
}
ctl() { bluetoothctl "$@" 2>/dev/null; }
now() { date +%T; }

chip_blocked() {   # 芯片电源那颗 rfkill（name=bt_power，归 vendor HAL/btpower 管）是否被软阻塞
    local r
    for r in /sys/class/rfkill/rfkill*; do
        [ "$(cat $r/type 2>/dev/null)" = bluetooth ] || continue
        [ "$(cat $r/name 2>/dev/null)" = bt_power ] || continue
        [ "$(cat $r/soft 2>/dev/null)" = 1 ] && echo "1:$(basename $r)" && return
    done
    echo "0:-"
}

bridge_pid() { run "pgrep -x bthci-bridge" | tr -d '\r' | grep -E '^[0-9]+$' | head -1; }

# ★ 通道是否已哑：**只看内核侧硬信号，不看 bluez 的 Powered**。
#   09-30 19:2x 就是反例——`Powered: yes`、UI 一切正常，而内核每 2s 刷
#   `hci0: command 0x0402 tx timeout`、`hciconfig` 连 local name 都读不出来（-110），
#   表现却是"所有设备连不上 + 一个也搜不到"。上一版只盯 Powered，所以全程没报。
#   两条同时成立才算哑（单看任一条都可能误判）：
#     A. `hciconfig -a hci0` 读不出 local name —— 读名字本身就是一条 HCI 命令，哑了就超时
#     B. `dmesg` 里 "tx timeout" 的总数比上一拍在涨（看增量，不看绝对值）
#   注意内层不能再写单引号（run() 已经把它塞进 su -c '...'），所以用 `tx.timeout` 顶空格。
TXTO_LAST=""
DEAD_LAST=0
channel_dead() {
    hciconfig -a hci0 2>/dev/null | grep -q "Can't read local name" || return 1
    local now
    now=$(run "dmesg 2>/dev/null | grep -c tx.timeout" | tr -d '\r' | tail -1)
    case "$now" in ''|*[!0-9]*) return 1 ;; esac
    if [ -n "$TXTO_LAST" ] && [ "$now" -gt "$TXTO_LAST" ]; then TXTO_LAST=$now; return 0; fi
    TXTO_LAST=$now
    return 1
}

counters() {   # 桥自己的计数（**必须按行取**：日志已 500MB+，`tail -c` 会把整行切成半截，
    # 于是 sed 匹配不到 → 显示 NOREAD，那是探针的假象不是"冻结"。行数上界 = 成本上界。）
    run "tail -n 400 $BTLOG | grep -a '转发=' | tail -1" | tr -d '\r' \
        | sed -n 's/.*转发=\([0-9]*\) 收回=\([0-9]*\) 回调=\([0-9]*\).*/\1 \2 \3/p' | tail -1
}

hci_state() {  # 内核侧 hci0 的真实状态
    # ⚠ 不要用 /sys/class/bluetooth/hci0/{address,flags}：本机（vendor 内核 + UART/pty 注册的 hci0）
    #   **这些属性根本不存在**，root 读也是 `No such file or directory`（09-30 实测）。
    #   我昨晚把"address 读不到"当过"空壳/卡死"签名，那条判据不成立，别再引用。
    # hciconfig 走 HCI socket，给的是真东西：flags（DOWN / UP RUNNING …）+ RX/TX 与 errors 计数。
    hciconfig hci0 2>/dev/null | awk 'NR<=3' | tr '\n' ' ' | sed 's/  */ /g'
}

snapshot() {   # 留一份事后能定位的现场：判定依据 + 两侧进程状态 + 内核/安卓最近日志
    local f=$SNAPD/bt-wedge-$(date +%m%d-%H%M%S).txt BP T
    mkdir -p "$SNAPD"
    BP=$(bridge_pid)
    {
        echo "=== BT-WEDGE-SNAPSHOT $(date +%F_%T) 触发原因: $1 ==="
        echo "--- bluez 侧 ---"
        ctl show | grep -E 'Controller|Powered|PowerState'
        echo "hci0: $(hci_state)"
        for r in /sys/class/rfkill/rfkill*; do
            [ "$(cat $r/type 2>/dev/null)" = bluetooth ] || continue
            echo "  $(basename $r) soft=$(cat $r/soft 2>/dev/null) hard=$(cat $r/hard 2>/dev/null) name=$(cat $r/name 2>/dev/null)"
        done
        echo "--- 判定用的原始证据 ---"
        echo "prev=[$PREV] 本轮=[${CNT:-NOREAD}] fwd_frozen=$FWD_FROZEN powfail=$FAILS restarts=$RESTARTS"
        echo "--- 桥日志（去掉事件洪水）---"
        run "tail -n 1200 $BTLOG | grep -av hciEventReceived" | tr -d '\r' | tail -20
        echo "--- 桥与 HAL 的线程状态（安卓侧，桥就在那边）---"
        # 解析放在本地做：su -c '...' 里塞 awk '…' 会被引号拼接打断（09-30 实测同类坑）
        run "cat /proc/${BP:-0}/task/*/stat 2>/dev/null" | tr -d '\r' \
            | awk -v me="$BP" '$1==me || $1 ~ /^[0-9]+$/ {printf "  tid=%s state=%s comm=%s\n", $1, $3, $2}' | head -8
        run "cat /proc/${BP:-0}/task/*/wchan 2>/dev/null; echo ---" | tr -d '\r' | head -8
        run "pidof android.hardware.bluetooth@aidl-service-qti" | tr -d '\r'
        echo "--- HAL logcat ---"
        run "logcat -d -t 300 2>/dev/null | grep -i -e bluetooth@ -e DataHandler -e ibs_handler -e INITIALIZATION | grep -v -e adbd -e ShellService | tail -12" | tr -d '\r'
        echo "--- 内核侧（容器读不到 dmesg，走安卓）---"
        run "dmesg 2>/dev/null | grep -i -e bluetooth -e hci -e btpower -e ttyHS -e glink | tail -15" | tr -d '\r'
    } > "$f" 2>&1
    echo "BT-SNAPSHOT $(now): 现场已存 $f"
}

launch_bridge() {   # ② 重拉桥：**所有**重拉路径都必须走这里，上限才管用
    if [ "$RESTARTS" -ge "$RESTART_MAX" ]; then
        snapshot "$1（重拉已达上限 $RESTART_MAX）"
        echo "BT-GIVEUP $(now): 已重拉 $RESTARTS 次仍不可用 ⇒ 停止再动 HAL（猛拉只会多造残留客户端）。"
        echo "          人工恢复：adb shell su -c 'pkill -x bthci-bridge' 后重跑一轮，或交还安卓让 framework 自己复位"
        GAVEUP=1
        return
    fi
    [ "$RESTARTS" = 0 ] && snapshot "$1（第 1 次重拉前的现场）"
    # 必须**先杀旧桥再拉新桥**：直接 nohup 会出现两个桥同时活着（09-30 实测我把这条写漏了，
    # 现场抓到 25065+32678 并存）= 两个 HAL 客户端抢同一颗 combo 芯片，正是最坏的那条路。
    # `</dev/null`：detached 进程别占着 adb 的 pty。这行历史上每次吃满超时（真因未定，
    # 实测单独 launch 一个 detached sleep 只要 0.1s）⇒ 不把超时当失败，发出后另行实证。
    OLD=$(bridge_pid)
    run "pkill -x bthci-bridge"
    sleep 2
    run "nohup $BTBIN --keep 0 </dev/null >>$BTLOG 2>&1 &"
    RESTARTS=$(( RESTARTS + 1 ))
    NEXT_JUDGE=$(( $(date +%s) + GRACE ))
    PREV_FWD=""; FWD_FROZEN=0; FAILS=0; KICKED=""
    sleep 2
    NEW=$(bridge_pid)
    N=$(run "pgrep -x bthci-bridge | wc -l" | tr -d '\r' | grep -E '^[0-9]+$' | tail -1)
    echo "BT-RESTART #$RESTARTS $(now): 旧桥=[${OLD:-无}] → 新桥=[${NEW:-查不到}] 进程数=$N（本轮上限 $RESTART_MAX，${GRACE}s 内不判定）"
    [ "$N" != 1 ] && echo "BT-RESTART WARN: 桥上进程数不是 1 ⇒ 多客户端风险，停止后续重拉" && GAVEUP=1
}

# 起步先让路：takeover 是"先拉桥、再拉本进程"，attach/setup 的空窗期不能当卡死
NEXT_JUDGE=$(( $(date +%s) + GRACE ))
echo "=== BT-KEEPALIVE START $(date +%F_%T) interval=${INTERVAL}s grace=${GRACE}s restart_max=${RESTART_MAX} 桥(安卓侧)=[$(bridge_pid)] ==="
while :; do
    SF=$(run "getprop init.svc.surfaceflinger" | tr -d '\r' | tail -1)
    if [ "$SF" = "running" ]; then
        echo "BT-KEEPALIVE FUSE $(now): surfaceflinger=running（已交还安卓），自退并把 HAL 客户端位还给安卓"
        exit 0
    fi
    if [ -z "$GAVEUP" ] && ! run "test -x $BTBIN && echo YES" | grep -q YES; then
        echo "BT-KEEPALIVE EXIT $(now): $BTBIN 不在，无事可做"
        exit 0
    fi

    BP=$(bridge_pid)
    CNT=$(counters)
    FWD=$(echo "$CNT" | awk '{print $1}')
    SHOW=$(ctl show)
    HASCTRL=$(echo "$SHOW" | grep -c '^Controller')

    # 先判"通道哑"：只有适配器在位时才值得花一次 hciconfig+dmesg（否则本来就读不出）
    DEAD=0
    if [ "$HASCTRL" = 1 ] && channel_dead; then
        DEAD=1
        # 哑会持续存在（今天从 19:1x 一直到重拉前），所以 60s 报一次就够，别冲掉日志
        if [ $(( $(date +%s) - DEAD_LAST )) -ge 60 ]; then
            DEAD_LAST=$(date +%s)
            echo "BT-DEADCHANNEL $(now): bluez 说 $(echo "$SHOW" | grep -E 'Powered|PowerState' | tr '\n' ' ')但内核侧读不出 local name 且 tx timeout 在涨；hci=[$(hci_state)] 计数=${CNT:-NOREAD} 桥=${BP:-安卓侧查不到} ⇒ 命令通道已哑（不是没上电）。同状态 60s 内不重复"
        fi
    fi

    if [ "$HASCTRL" = 1 ] && [ "$DEAD" = 0 ] && echo "$SHOW" | grep -q 'Powered: yes'; then
        # 交叉核对：bluez 说上电了，内核侧 hci0 却不在 UP RUNNING ⇒ 明报不一致，但仍按健康处理
        # （只报不动作——上一版就是因为把 sysfs 读不到当"卡死"才疯狂重拉）
        hci_state | grep -q "UP RUNNING" || echo "BT-KEEPALIVE INCONSISTENT $(now): bluez Powered: yes 但 hci: $(hci_state)"
        [ "$FAILS" != 0 ] && echo "BT-KEEPALIVE RECOVERED $(now): Powered: yes（此前连轮 $FAILS）"
        # 被别人救活（人工 pkill 后重跑、或安卓自己复位）就重新开始守，别抱着 GAVEUP 不放
        [ -n "$GAVEUP" ] && { echo "BT-GIVEUP CLEAR $(now): 蓝牙已可用，恢复守门"; GAVEUP=""; RESTARTS=0; }
        FAILS=0; FWD_FROZEN=0; PREV=$CNT
        sleep "$INTERVAL"; continue
    fi

    # ★ `bt_power soft=1` 是**正常休眠，不是故障**（09-30 用户提出、实测支持，我此前的"定案"过重）：
    #   这就是 vendor HAL 的带内休眠(IBS)电源管理 —— logcat 里 `IBS_WAKE_IND/IBS_SLEEP_IND` +
    #   `SerialClockVote: UART CLK ON/OFF` + `Release wakelock` 在**健康期也在打**；
    #   而且 `system_suspend=stopped`、wake_lock 持有 `hal_bluetooth_lock qoderdbg`、
    #   安卓 BT app 进程数=0 —— 三个"嫌疑犯"都排除了。
    #   实测证据：同一座**从未重拉**的桥，soft 回 0 后计数从 152 直接走到 651/659、
    #   `hciconfig` = `UP RUNNING`、`TX errors=0`（"睡了叫得醒、醒了继续跑"）；
    #   00:52:15 卡在 `转发=50` → 00:54:54 soft 归 0 → root power on 一次 → `Powered: yes`。
    #   ⇒ 唯一真正要管的情形是"**睡了叫不醒**"；目前还没有一次证据出现过。
    #   ⇒ 正确动作是**等 + 到位后 power on 一次**；重拉桥反而是伤害（每次重拉注销 hci0，
    #     把正在逼近的电源窗口又吹掉 —— 09-30 前 17 次重拉一次都没治好，就是这个机制）。
    # 通道已经哑（DEAD=1）时不能再算"芯片在睡"——睡是叫得醒的，哑不是；今天 19:2x 就是
    # soft=0、Powered=yes 的哑，被上一版误判成"等它醒"，于是一直不动作。
    CB=$(chip_blocked)
    if [ "$DEAD" = 0 ] && [ "${CB%%:*}" = 1 ] && [ $(( $(date +%s) - CB_LAST )) -ge 300 ]; then
        CB_LAST=$(date +%s)
        BV=$(run "getprop persist.vendor.bluetooth.state" | tr -d '\r' | tail -1)
        echo "BT-CHIP-BLOCKED $(now): $(echo "$SHOW" | grep -E 'Powered|PowerState' | tr '\n' ' ')[ctl=$HASCTRL] 计数=${CNT:-NOREAD} hci: $(hci_state) 桥=${BP:-安卓侧查不到} ${CB#*:}(bt_power) soft=1 persist.vendor.bluetooth.state=${BV:-查不到}"
        echo "          ⇒ 芯片在正常休眠（HAL 的 IBS 电源管理，健康期也这样）。本进程**等**它醒（soft 回 0）后自动 power on（root，一次即可），期间不重拉桥（重拉会注销 hci0、把醒来窗口吹掉）。绝不手动解这颗 rfkill：电源归 btpower/HAL 协调，是红线。只有'叫不醒'才算故障"
        PREV=$CNT; sleep "$INTERVAL"; continue
    fi
    [ "$DEAD" = 0 ] && [ "${CB%%:*}" = 1 ] && { PREV=$CNT; sleep "$INTERVAL"; continue; }

    # 掉电/无适配器：整行证据先落日志。每个数都必须是被读到的，读不到写 NOREAD——
    # 否则"没测到"会伪装成"没发生"（见 工作总结 §探针自证纪律）
    echo "BT-KEEPALIVE NOT-POWERED $(now): $(echo "$SHOW" | grep -E 'Powered|PowerState' | tr '\n' ' ')[ctl=$HASCTRL] 计数=${CNT:-NOREAD} hci: $(hci_state) 桥=${BP:-安卓侧查不到} 重拉=$RESTARTS 冻轮=$FWD_FROZEN"
    if [ -n "$GAVEUP" ]; then
        PREV=$CNT; sleep "$INTERVAL"; continue
    fi
    if [ "$(date +%s)" -lt "$NEXT_JUDGE" ]; then
        echo "BT-KEEPALIVE GRACE $(now): 距下次可判定还有 $(( NEXT_JUDGE - $(date +%s) ))s"
        PREV=$CNT; sleep "$INTERVAL"; continue
    fi


    if [ -n "$FWD" ] && [ "$FWD" = "$PREV_FWD" ]; then
        FWD_FROZEN=$(( FWD_FROZEN + 1 ))
    else
        FWD_FROZEN=0
    fi
    PREV_FWD=$FWD

    # 要不要动手：无适配器（hci0 已被注销）／通道已哑／ power on 要不来 ／ 转发连轮冻住
    WEDGE=0
    if [ "$DEAD" = 1 ]; then
        # 哑的时候别再做 power on：那条调用自己也走不通（今天实测 bluez 侧 25s 超时），
        # 只会白占一拍
        WEDGE=1
    elif [ "$HASCTRL" != 1 ]; then
        WEDGE=1
    else
        bluetoothctl power on >/dev/null 2>&1
        sleep 3
        if bluetoothctl show 2>/dev/null | grep -q 'Powered: yes'; then
            echo "BT-KEEPALIVE POWERED-AGAIN $(now): power on 生效（此前连轮 $FAILS）"
            FAILS=0; PREV=$CNT; sleep "$INTERVAL"; continue
        fi
        FAILS=$(( FAILS + 1 ))
        { [ "$FAILS" -ge "$POWFAIL_MAX" ] || [ "$FWD_FROZEN" -ge 3 ]; } && WEDGE=1
    fi
    if [ "$WEDGE" = 0 ]; then
        PREV=$CNT; sleep "$INTERVAL"; continue
    fi

    # ① 内核侧重踢（每段只踢一次）：比动 HAL 客户端便宜一个量级。
    #    但**通道已哑时不踢**——`hciconfig hci0 reset` 自己就是一条 HCI 命令，
    #    今天实测它同样 `Connection timed out`，白等 12 秒而已。
    if [ -z "$KICKED" ] && [ "$HASCTRL" = 1 ] && [ "$DEAD" = 0 ]; then
        KICKED=1
        hciconfig hci0 up >/dev/null 2>&1
        echo "BT-KICK $(now): 已 hciconfig hci0 up（桥没动），下一轮看是否恢复"
        PREV=$CNT; sleep "$INTERVAL"; continue
    fi
    # ②/③ 重拉桥（有上限）或收手
    launch_bridge "power_on 连轮=$FAILS 转发冻住轮=$FWD_FROZEN 适配器在位=$HASCTRL 桥=${BP:-无}"
    PREV=$CNT
    sleep "$INTERVAL"
done
