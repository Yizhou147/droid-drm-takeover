#!/system/bin/sh
# storage-fix.dev.sh —— 在安卓侧跑（root、init mount ns）。由 storage-fix.sh 推上去。
# 为什么需要它：容器 boot 时 bind 的是安卓那会儿的 fuse 超级块；安卓每次重启框架
# （交还时的 start、MediaProvider 崩、用户解锁）都会 mount 出一个新的，容器抱着的
# 旧那份之后一律 ENOTCONN，跟权限无关。这里等新的活挂载出现，然后接回去。
#
# 判据只读 /proc/<pid>/mountinfo。绝不 stat/ls 容器里那个挂载来判断死活：轮里
# system_server 是被 SIGSTOP 的，那种状态下探测会永久挂住（见 工作总结 §3.12）。
# 验收是在“框架已经回来、源理应当活”的时刻做的，且一律带 timeout。
#
# 用法: sh storage-fix.dev.sh [等待秒数=60]
WAIT=${1:-60}
SR=/data/local/tmp/storage-rebind
PIDF=/data/local/Droidspaces/Pids

[ -x "$SR" ] || { echo "NO-REBIND-BIN"; exit 1; }
CP=$(cat $PIDF/*.pid 2>/dev/null | head -1)
case "$CP" in
    ''|*[!0-9]*) echo "NO-CONTAINER-PID"; exit 1 ;;
esac
[ -r "/proc/$CP/mountinfo" ] || { echo "CONTAINER-NOT-RUNNING pid=$CP"; exit 1; }
echo "container_pid=$CP"

END=$(( $(cut -d. -f1 /proc/uptime) + WAIT ))
LSRC=1
while :; do
    # 先在**主机**上确认这份源当下真的能用，再动手。安卓刚重启框架时 /storage/emulated
    # 会处于"已挂但 daemon 未就绪"甚至反复换超级块的窗口期，这时候接过去等于接一个马上
    # 要被换掉的挂载，白忙还留一堆死挂载。主机 stat 是安全的（根是活文件系统）。
    if ! timeout 4 ls -U /storage/emulated/0 >/dev/null 2>&1; then
        NOW=$(cut -d. -f1 /proc/uptime)
        [ "$NOW" -ge "$END" ] && { echo "HOST-SOURCE-DEAD 安卓侧 /storage/emulated/0 到超时仍不可用"; echo "STORAGE-STALE reason=host-dead"; exit 2; }
        sleep 3
        continue
    fi

    "$SR" "$CP" || echo "REBIND-NONZERO rc=$?"

    # 容器里实测能不能列 /storage/emulated/0（能列 = 真的接上了）
    LSRC=$(timeout 6 nsenter -t $CP -m -- /bin/sh -c \
        'export PATH=/usr/bin:/bin; timeout 4 ls -U /storage/emulated/0 >/dev/null 2>&1; echo $?')
    case "$LSRC" in *0) echo "STORAGE-OK guest_ls_rc=$LSRC"; exit 0 ;; esac

    NOW=$(cut -d. -f1 /proc/uptime)
    [ "$NOW" -ge "$END" ] && { echo "STORAGE-STALE guest_ls_rc=$LSRC check=$($SR -c "$CP" | tr '\n' ' ')"; exit 2; }
    sleep 3
done
