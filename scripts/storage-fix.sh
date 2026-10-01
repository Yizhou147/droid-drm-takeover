#!/bin/bash
# storage-fix.sh —— 交还安卓之后，把容器里那份"安卓存储"重新接上。
#
# 根因见 工作总结 §3.12：容器 boot 时 bind 的是当时那个 fuse 超级块，安卓每次重启框架
# 都会 mount 出新的，旧的那份从此 ENOTCONN —— 表现为"拒绝访问"，跟授权无关，改权限没用。
#
# 真正干活的是 storage-fix.dev.sh（推到设备上以 root 跑），本脚本只做"按需 push + 调用 +
# 汇总判据"。分成两个文件是因为 adb→su -c→设备 shell 三层引号会打碎命令（§3.9 老教训）。
#
# 用法: storage-fix.sh [等待秒=60]     退出码 0 = STORAGE-OK
ROOT="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
WAIT=${1:-60}

. "$(cd "$(dirname "$0")/.." && pwd)/scripts/adb-pick.sh"   # 本机/回环优先 + getprop 实测，见该文件头注
DEV=$(pick_adb_dev_with_endpoints 6)
[ -n "$DEV" ] || { echo "NO-ADB-DEVICE"; exit 1; }

BIN=$ROOT/bin/storage-rebind
DSH=$ROOT/scripts/storage-fix.dev.sh
[ -x "$BIN" ] || { echo "NO-BIN: 先 make bin/storage-rebind"; exit 1; }
[ -f "$DSH" ] || { echo "NO-DEV-SCRIPT $DSH"; exit 1; }

push_if_changed() {
    local src=$1 dst=$2 a b
    a=$(stat -c %s "$src")
    b=$(timeout 12 adb -s "$DEV" shell "su -c 'stat -c %s $dst 2>/dev/null'" 2>/dev/null | tr -d '\r')
    if [ "$a" != "$b" ]; then
        timeout 30 adb -s "$DEV" push "$src" "$dst" >/dev/null || return 1
        timeout 12 adb -s "$DEV" shell "su -c 'chmod 755 $dst'" >/dev/null
        echo "PUSHED $dst ($a bytes)"
    fi
}

push_if_changed "$BIN" /data/local/tmp/storage-rebind || { echo "PUSH-FAIL bin"; exit 1; }
push_if_changed "$DSH" /data/local/tmp/storage-fix.dev.sh || { echo "PUSH-FAIL sh"; exit 1; }

echo "=== STORAGE-FIX START $(date +%T) wait=${WAIT}s ==="
# 外层 timeout 比内层等待多给 40s：设备侧脚本自己有 deadline，这里只防 adb 抽风卡死
timeout $((WAIT + 40)) adb -s "$DEV" shell "su -c 'sh /data/local/tmp/storage-fix.dev.sh $WAIT'" 2>&1 | tr -d '\r'
rc=${PIPESTATUS[0]}
echo "=== STORAGE-FIX END rc=$rc ==="
exit $rc
