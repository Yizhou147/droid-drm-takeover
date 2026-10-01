#!/usr/bin/env bash
# adb-pick.sh —— 所有"往安卓发命令"的地方都必须用这里选出来的地址。
#
# 为什么必须有它（10-01 实测，直接导致用户强制重启）：
#   原来每个脚本都是 `DEV=$(adb devices | awk '$2=="device"{print $1; exit}')` —— 取**行序第一个**。
#   换过网络之后，设备列表里会同时留着一条已经死掉的无线调试地址（实测 `172.16.28.69:41043`），
#   它还排在 `emulator-5554` 前面，于是 19:47 那次交还把
#   `setprop ctl.start vendor.qti.hardware.display.composer; start` 全发给了那个死地址，
#   一路 `adb: device offline` ⇒ 安卓没被拉回来 = 黑屏，只能长按电源。
#
# 三条规矩：
#   1) 本机/回环优先：`emulator-*` 与 `127.0.0.1:5555` 走 loopback（adbd 常驻监听 TCP 5555，
#      `persist.adb.tcp.port` 实测=5555），与连哪个 WiFi 无关；
#   2) 每一个候选都要**真的能回话**（getprop 实测）才算，不看列表状态也不看措辞；
#   3) 这里**绝不 kill-server**：容器与安卓共享 netns，adb server 只有 127.0.0.1:5037 一份，
#      谁重启它，另一个容器的通道就跟着变 unauthorized（今天两边都被这么搞崩过）。

pick_adb_dev() {
    local tmo="${1:-6}" out first rest line picked=""
    timeout 15 adb start-server >/dev/null 2>&1
    out=$(timeout 12 adb devices 2>/dev/null | awk '$2=="device"{print $1}')
    [[ -n "$out" ]] || return 1
    first=$(printf '%s\n' "$out" | grep -E '^(emulator-|127\.0\.0\.1:)')
    rest=$(printf '%s\n' "$out" | grep -vE '^(emulator-|127\.0\.0\.1:)')
    for line in $first $rest; do
        if timeout "$tmo" adb -s "$line" shell getprop ro.build.version.sdk >/dev/null 2>&1; then
            picked="$line"; break
        fi
    done
    [[ -n "$picked" ]] || return 1
    printf '%s' "$picked"
}

# 列表里没有可用地址时再试配置里的地址（只补连，不动 server）
pick_adb_dev_with_endpoints() {
    local tmo="${1:-6}" ep picked=""
    picked=$(pick_adb_dev "$tmo") && { printf '%s' "$picked"; return 0; }
    for ep in ${ADB_ENDPOINTS:-}; do
        timeout 12 adb connect "$ep" >/dev/null 2>&1 || continue
        if timeout "$tmo" adb -s "$ep" shell getprop ro.build.version.sdk >/dev/null 2>&1; then
            printf '%s' "$ep"; return 0
        fi
    done
    return 1
}
