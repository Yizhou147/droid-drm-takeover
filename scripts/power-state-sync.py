#!/usr/bin/env python3
"""power-state-sync — 修小米 piano 电池驱动电流符号与内核 power_supply ABI 相反
（实测充电时 current_now=-4.9A，ABI 规定正=流入=充电；upower 在 AC 在线时按
current 符号判充放电，托盘永远显示"放电"）。

方案：bind-mount 一个取反过的 current_now 盖住 sysfs 文件，周期 kick uevent 让
upower 重读。关键坑：/sys/class/power_supply/battery 与 devices 路径同 inode，
bind 之后自己再也读不到真值 —— 必须在 mount **之前** open 住真文件（fd 穿透
覆盖），之后用 pread 采样。
必须 root、从 shell 会话跑（与 pc-keyd 同规格，勿用 systemd）。
"""
import os, subprocess, sys, time

BATT_DIR = "/sys/devices/platform/soc/soc:mca_business_battery/power_supply/battery"
REAL_CUR = BATT_DIR + "/current_now"
CLS_CUR = "/sys/class/power_supply/battery/current_now"
FAKE = "/run/power-fix/current_now"
KICK = BATT_DIR + "/uevent"
INTERVAL = 5

os.makedirs("/run/power-fix", exist_ok=True)
real_fd = os.open(REAL_CUR, os.O_RDONLY)  # bind 前拿住真身

def mounted():
    for l in open("/proc/mounts"):
        if l.split()[1] == CLS_CUR:
            return True
    return False

if not mounted():
    v = os.pread(real_fd, 24, 0).decode().strip()
    open(FAKE, "w").write(v + "\n")
    subprocess.run(["mount", "--bind", FAKE, CLS_CUR], check=True)

def flipped(v):
    try:
        n = int(v)
    except ValueError:
        return None
    return str(-n)

while True:
    try:
        v = os.pread(real_fd, 24, 0).decode().strip()
        out = flipped(v)
        if out is not None:
            cur = open(FAKE).read().strip()
            if cur != out:
                with open(FAKE, "w") as f:
                    f.write(out + "\n")
        with open(KICK, "w") as f:
            f.write("change\n")
    except Exception as e:
        print("sync err:", e, file=sys.stderr)
    time.sleep(INTERVAL)
