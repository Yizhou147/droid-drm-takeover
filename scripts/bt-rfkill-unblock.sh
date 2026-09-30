#!/bin/bash
# bt-rfkill-unblock.sh — 把 KDE 里"打开蓝牙开关"那一步自动化：解掉 **class 级** 的蓝牙软阻塞。
#
# 为什么需要它（09-30 实测，别再猜第二遍）：
#   bluedevil 的托盘 applet 与系统设置页判断"蓝牙是否禁用"用的是
#   `BluezQt::Manager::isBluetoothBlocked()` —— 那是 **/dev/rfkill 上 type=bluetooth 的聚合状态**，
#   不是 bluez 的 `Adapter1.Powered`。本机内核里有**两颗** type=bluetooth 的 rfkill：
#     rfkill0 name=bt_power  ← vendor 的芯片电源门（接管轮里常年 soft=1）
#     rfkillN name=hci0      ← 我们自己那颗（soft=0，工作正常）
#   只要有一颗报 blocked，聚合就是"被阻塞" ⇒ 托盘无图标 + 设置页显示"已禁用"，
#   **而鼠标照连、声音照放**（功能与显示分家）。
#   用户平时"手动把蓝牙开关打开一下，显示就正常了"＝那次点击走了
#   `BluezQt::Manager::setBluetoothBlocked(false)` → 写 /dev/rfkill 解除 class 阻塞
#   （这条路不经过 bluez，所以我那条 dbus deny 挡不到它）。本脚本就是自动做这一下。
#
# 与红线的关系：§蓝牙红线禁的是**手动驱动 ttyHS0/btpower 的电源 ioctl** 那套；这里写的是
# 内核 rfkill 框架的标准入口（`/dev/rfkill` 的 RFKILL_OP_CHANGE），等价于用户自己在 UI 上
# 做的那一步。09-30 实测：写入后 `bt_power soft 1→0`，桥与已连接的鼠标**都没掉**。
# 仍按保守做法执行：**每轮只做一次**（蓝牙上电之后），不进轮询循环反复动它。
# 用法：bash bt-rfkill-unblock.sh [--dry-run]
DRY=""
[ "$1" = "--dry-run" ] && DRY=1
python3 - "$DRY" <<'PY'
import os, struct, glob, sys
dry = sys.argv[1] == "--dry-run"
targets = []
for d in glob.glob('/sys/class/rfkill/rfkill*'):
    try:
        typ = open(d + '/type').read().strip()
        name = open(d + '/name').read().strip()
        soft = open(d + '/soft').read().strip()
    except OSError as e:
        print(f"BT-UNBLOCK SKIP: {d} 读不到（{e}）"); continue
    if typ == 'bluetooth' and soft == '1':
        targets.append((int(os.path.basename(d).replace('rfkill', '')), name))
if not targets:
    print("BT-UNBLOCK NOTHING: 没有处于 soft-block 的 type=bluetooth rfkill（显示应当正常）")
    raise SystemExit(0)
if dry:
    print("BT-UNBLOCK DRY-RUN: 将解阻塞", targets); raise SystemExit(0)
rc = 0
for idx, name in targets:
    try:
        fd = os.open('/dev/rfkill', os.O_WRONLY)
        # 传统 8 字节 rfkill_event：{u32 idx; u8 type; u8 op; u8 soft; u8 hard}
        # type=2 BLUETOOTH, op=2 RFKILL_OP_CHANGE, soft=0 hard=0 ⇒ 对该设备解软阻塞
        os.write(fd, struct.pack('=IBBBB', idx, 2, 2, 0, 0))
        os.close(fd)
        after = open(f'/sys/class/rfkill/rfkill{idx}/soft').read().strip()
        print(f"BT-UNBLOCK OK: rfkill{idx}({name}) 已解阻塞，soft 现={after}")
        rc = rc or (after != '0')
    except OSError as e:
        print(f"BT-UNBLOCK FAIL: rfkill{idx}({name}) 写入失败 {e}"); rc = 1
raise SystemExit(rc)
PY
