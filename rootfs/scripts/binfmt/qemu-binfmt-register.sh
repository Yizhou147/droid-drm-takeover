#!/bin/sh
set -eu

BINFMT_MISC="/proc/sys/fs/binfmt_misc"

log() { echo "qemu-binfmt: $*"; }

# 检查内核支持
if ! grep -q binfmt_misc /proc/filesystems 2>/dev/null; then
    log "内核不支持 binfmt_misc，跳过"
    exit 0
fi

# 必要时挂载
if ! grep -q "$BINFMT_MISC" /proc/mounts; then
    if ! mount -t binfmt_misc binfmt_misc "$BINFMT_MISC"; then
        log "挂载 binfmt_misc 失败，跳过"
        exit 0
    fi
fi

# 处理完成
exit 0
