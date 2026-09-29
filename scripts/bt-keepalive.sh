#!/bin/bash
# bt-keepalive.sh — 接管轮内的蓝牙守门人：保证"默认开 + 关不掉"，并在 HCI 通道卡死时按
# 最小代价恢复；恢复不了就**收手并留现场**，不再反复重拉。
#
# 为什么不是"掉电就重拉桥"（09-30 第一轮被实测打脸，写死在这儿）：
#   那一轮 6 分钟内 4 次重拉，每次新 attach 都能 initializationComplete(SUCCESS)，
#   但 30~90s 内又死；最后一死的签名是 `转发=50 收回=50 回调=51` **三个计数一起冻住**
#   （09-29 那次的签名是"收回暴涨到 4.8 万、转发冻在 520"的单向死）。
#   ⇒ 重拉没治好，反而每轮多制造一个 HAL 客户端；日志里早就出现过
#     `DataHandler::Open: Returning as protocol already added` + `INITIALIZATION_ERROR`
#     ——HAL 被残留/多个客户端占着的签名。**猛拉是有害的**，所以下面三级台阶 + 上限。
#
# 三级台阶（判据以桥自己的计数为准——那是 HCI 通道的地表事实，bluetoothd 的 Powered 只是下游表象）：
#   ① `hciconfig hci0 up`：内核侧重踢，零成本（桥 setup 时自己也是这么干的）
#   ② 仍不行才重拉桥，整轮最多 RESTART_MAX 次
#   ③ 到顶就 BT-GIVEUP：不再动任何东西，并 dump 一份现场到 logs/bt-wedge-*.txt 供事后定位
#   桥刚起来的 GRACE 秒内不判定（attach/注册 hci0 本来就有空窗，拿它当卡死=自己造抖动）
#
# 常态职责另有两层：
#   · 熔断（红线）：init.svc.surfaceflinger=running ⇒ 立刻自退，把 HAL 客户端位还给安卓；
#   · 保活：Powered 不是 yes 就先 `bluetoothctl power on`（root 侧；策略层挡不住的路径归这儿）。
# 本进程只做蓝牙侧动作：不碰 rfkill ioctl、不碰 ttyHS0/btpower、不重启任何服务。
DEV=$(adb devices | awk '$2=="device"{print $1; exit}')
[ -n "$DEV" ] || { echo "BT-KEEPALIVE EXIT $(date +%T): 没有 adb 设备，无法观测安卓侧状态"; exit 0; }
BTBIN=${BTBIN:-/data/local/tmp/bthci-bridge}
BTLOG=${BTLOG:-/data/local/tmp/bt-bridge.log}
# 现场目录与接管轮日志同处 = <项目根>/logs（本脚本在 <项目根>/droid-drm-takeover/scripts/，剥三层）
SNAPD=${SNAP_DIR:-$(dirname "$(dirname "$(dirname "$(readlink -f "$0")")")")/logs}
INTERVAL=${INTERVAL:-10}
GRACE=${GRACE:-45}          # 桥拉起后的宽限期（秒）
RESTART_MAX=${RESTART_MAX:-2}
POWFAIL_MAX=${POWFAIL_MAX:-2}
PREV=""                     # 上一轮采到的计数（进现场快照用）
PREV_FWD=""
FWD_FROZEN=0                # 转发计数连续几轮没动
FAILS=0                     # power on 连轮要不来
RESTARTS=0
KICKED=""                   # 每轮只踢一次内核，别刷
GAVEUP=""

run() {
    local out rc
    out=$(timeout 8 adb -s "$DEV" shell "su -c '$1'" 2>&1); rc=$?
    [ $rc -eq 124 ] && echo "BT-KEEPALIVE RUN-TIMEOUT(8s): $1"
    printf '%s\n' "$out"
}
ctl() { bluetoothctl "$@" 2>/dev/null; }
now() { date +%T; }

bridge_age() {   # 桥进程已存活秒数（容器与安卓共享 PID ns，这边直接读 /proc）
    # 不用 /proc/PID/stat 的第 22 个字段：本机实测那串数对不上（4744916 vs uptime 9691，
    # 算出来 age=-37733s）。改 /proc/PID 目录的 ctime ≈ 进程创建时刻，实测 4s 的进程报 4s。
    local c
    c=$(stat -c %Y /proc/"$1" 2>/dev/null)
    case "$c" in ''|*[!0-9]*) echo -1; return ;; esac
    echo $(( $(date +%s) - c ))
}

counters() {     # 桥自己的计数（tail -c 限量：日志已 270 万行，绝不整读）
    run "tail -c 4000 $BTLOG | grep -a '转发=' | tail -1" | tr -d '\r' \
        | sed -n 's/.*转发=\([0-9]*\) 收回=\([0-9]*\) 回调=\([0-9]*\).*/\1 \2 \3/p' | tail -1
}

snapshot() {   # 留一份事后能定位的现场：判定依据 + 两侧进程状态 + 内核/安卓最近日志
    local f=$SNAPD/bt-wedge-$(date +%m%d-%H%M%S).txt
    mkdir -p "$SNAPD"
    {
        echo "=== BT-WEDGE-SNAPSHOT $(date +%F_%T) 触发原因: $1 ==="
        echo "--- bluez 侧 ---"
        ctl show | grep -E 'Controller|Powered|PowerState'
        echo "hci0.flags=$(cat /sys/class/bluetooth/hci0/flags 2>&1) address=$(cat /sys/class/bluetooth/hci0/address 2>&1)"
        for r in /sys/class/rfkill/rfkill*; do
            [ "$(cat $r/type 2>/dev/null)" = bluetooth ] || continue
            echo "  $(basename $r) soft=$(cat $r/soft 2>/dev/null) hard=$(cat $r/hard 2>/dev/null)"
        done
        echo "--- 桥（共享 PID ns，从这边读）---"
        local BP T
        BP=$(pgrep -x bthci-bridge | head -1)
        echo "bridge pid=${BP:-DEAD} age=${BP:+$(bridge_age "$BP")}s"
        for T in ${BP:+/proc/$BP/task/*}; do
            echo "  tid=$(basename $T) state=$(awk '{print $3}' $T/stat 2>/dev/null) wchan=$(cat $T/wchan 2>/dev/null)"
        done
        echo "--- 判定用的原始证据 ---"
        echo "prev=[$PREV] 本轮=[${CNT:-NOREAD}] fwd_frozen=$FWD_FROZEN powfail=$FAILS restarts=$RESTARTS"
        echo "--- 桥日志（去掉事件洪水）---"
        run "tail -c 3000 $BTLOG | grep -av hciEventReceived" | tr -d '\r' | tail -20
        echo "--- HAL 侧（安卓）---"
        run "logcat -d -t 200 2>/dev/null | grep -iE 'bluetooth@|DataHandler|ibs_handler|INITIALIZATION' | tail -12" | tr -d '\r'
        echo "--- 内核侧（容器读不到 dmesg，走安卓）---"
        run "dmesg 2>/dev/null | grep -iE 'bluetooth|hci|btpower|ttyHS|glink' | tail -15" | tr -d '\r'
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
    # `</dev/null`：detached 进程别占着 adb 的 pty。本轮这行仍会吃 8s 超时，真因未定
    # ⇒ 不把超时当失败，发出后用 pgrep 实证。
    run "nohup $BTBIN --keep 0 </dev/null >>$BTLOG 2>&1 &"
    RESTARTS=$(( RESTARTS + 1 ))
    PREV_FWD=""; FWD_FROZEN=0; FAILS=0; KICKED=""
    echo "BT-RESTART #$RESTARTS $(now): 已发出重拉（本轮上限 $RESTART_MAX），接下来 ${GRACE}s 内不判定"
}

echo "=== BT-KEEPALIVE START $(date +%F_%T) interval=${INTERVAL}s grace=${GRACE}s restart_max=${RESTART_MAX} ==="
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

    BP=$(pgrep -x bthci-bridge | head -1)
    AGE=${BP:+$(bridge_age "$BP")}; AGE=${AGE:--1}
    CNT=$(counters)
    FWD=$(echo "$CNT" | awk '{print $1}')
    SHOW=$(ctl show)
    HASCTRL=$(echo "$SHOW" | grep -c '^Controller')

    if [ "$HASCTRL" = 1 ] && echo "$SHOW" | grep -q 'Powered: yes'; then
        [ "$FAILS" != 0 ] && echo "BT-KEEPALIVE RECOVERED $(now): Powered: yes（此前连轮 $FAILS）"
        # 别人（人工 pkill 后重跑、或安卓自己复位）把它救活了，就重新开始守，别抱着 GIVEUP 不放
        [ -n "$GAVEUP" ] && { echo "BT-GIVEUP CLEAR $(now): 蓝牙已可用，恢复守门"; GAVEUP=""; RESTARTS=0; }
        FAILS=0; FWD_FROZEN=0; PREV=$CNT
        sleep "$INTERVAL"; continue
    fi

    # 掉电/无适配器：整行证据先落盘。每个数都必须是被读到的，读不到写 NOREAD——
    # 否则"没测到"会伪装成"没发生"（见 工作总结 §探针自证纪律）
    echo "BT-KEEPALIVE NOT-POWERED $(now): $(echo "$SHOW" | grep -E 'Powered|PowerState' | tr '\n' ' ')[ctl=$HASCTRL] 计数=${CNT:-NOREAD} bridge=${BP:-DEAD} age=${AGE}s 重拉=$RESTARTS 冻轮=$FWD_FROZEN"
    if [ -n "$GAVEUP" ]; then
        PREV=$CNT; sleep "$INTERVAL"; continue
    fi
    if [ "$AGE" -ge 0 ] && [ "$AGE" -lt "$GRACE" ]; then
        echo "BT-KEEPALIVE GRACE $(now): 桥才起 ${AGE}s，等它把 setup 走完"
        PREV=$CNT; sleep "$INTERVAL"; continue
    fi

    if [ -n "$FWD" ] && [ "$FWD" = "$PREV_FWD" ]; then
        FWD_FROZEN=$(( FWD_FROZEN + 1 ))
    else
        FWD_FROZEN=0
    fi
    PREV_FWD=$FWD

    # 要不要动手：无适配器（hci0 已被注销）／ power on 要不来 ／ 转发连轮冻住
    WEDGE=0
    if [ "$HASCTRL" != 1 ]; then
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

    # ① 内核侧重踢（只踢一次）：比动 HAL 客户端便宜一个量级
    if [ -z "$KICKED" ] && [ "$HASCTRL" = 1 ]; then
        KICKED=1
        hciconfig hci0 up >/dev/null 2>&1
        echo "BT-KICK $(now): 已 hciconfig hci0 up（桥没动），下一轮看是否恢复"
        PREV=$CNT; sleep "$INTERVAL"; continue
    fi
    # ②/③ 重拉桥（有上限）或收手
    launch_bridge "power_on 连轮=$FAILS 转发冻住轮=$FWD_FROZEN 适配器在位=$HASCTRL"
    PREV=$CNT
    sleep "$INTERVAL"
done
