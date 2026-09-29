#!/bin/bash
# Native path: kwin_wayland IS the top-level compositor, talking to the display
# daemon directly through its built-in "anland" backend (--anland). There is no
# weston layer and no nested kwin — kwin replaces both. The patched kwin_wayland
# must be installed (see kdefix/build.sh, which builds the .deb with the anland
# backend baked in).
#
# 本文件是 /usr/local/bin/startanland-kde.sh 的仓内正源（09-28 收编）。
# 安装：sudo cp scripts/startanland-kde.sh /usr/local/bin/startanland-kde.sh
# anland 定案（09-28）：座位 IM=fcitx5（kwinrc [Wayland]InputMethod，由 desk-stop
# 交还时恢复）+ fcitx5 启动后**默认英文态**（fcitx5-remote -c＝inactive 直出），
# 中文由安卓输入法组词、fcitx5 纯透传——这是星火/zcode/trae"输入 nihao→ni"残留
# 的治本形态（双记账互踩消除，见工作总结同日条目）。
SOCK="${1:-/run/display.sock}"

pkill -9 plasmashell 2>/dev/null; pkill -9 kwin_wayland 2>/dev/null; pkill -9 startplasma 2>/dev/null; pkill -9 org_kde_powerdevil 2>/dev/null
sleep 1
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
mkdir -p "$XDG_RUNTIME_DIR"; chmod 0700 "$XDG_RUNTIME_DIR"
unset DISPLAY
# pc-keyd 组合键守护：必须 shell 上下文启动（systemd 注入被内核丢弃，09-23 实锤）
# 09-27 起默认关闭（uinput 键盘令安卓常驻物理键盘通知）；需要 PC 页组合键时手动运行 nohup python3 /usr/local/bin/pc-keyd.py 再重进会话
# pgrep -f "pc-keyd.py" >/dev/null 2>&1 || nohup python3 /usr/local/bin/pc-keyd.py > /tmp/pc-keyd.log 2>&1 &
export ANLAND_SOCKET=/run/display.sock
export ANLAND=1
export ANLAND_DRM_DEVICE=/dev/dri/renderD128
export MESA_LOADER_DRIVER_OVERRIDE=kgsl GALLIUM_DRIVER=kgsl FD_FORCE_KGSL=1
export QT_QPA_PLATFORM=wayland
[ -c /dev/uinput ] || { mknod /dev/uinput c 10 223; chmod 666 /dev/uinput; }
rm -f "$XDG_RUNTIME_DIR"/wayland-* 2>/dev/null

# anland v5 中文输入依赖 Qt 走 fcitx5 桥（QT_IM_MODULE 缺失时 Qt 直连合成器 text-input，
# 与 anland 的"拼音镜像+退格擦除"流互相踩踏）。全局 /etc/environment 必须保持干净
# （DRM 桌面的虚拟键盘依赖这点），所以只在 anland 会话级注入：
export QT_IM_MODULE=fcitx5
export GTK_IM_MODULE=fcitx5
# 入场归一（09-29）：kwinrc [Wayland]InputMethod 是两桌面共享的文件，DRM 轮里手动切过
# plasma-keyboard 会泄漏到 anland（用户要求：每次进 anland 必须 fcitx5）。不依赖
# desk-stop 恢复，每个 anland 入场点自己写一遍。注意 sed 空匹配也返回 0，必须先 grep。
if grep -q '^InputMethod\[' ~/.config/kwinrc 2>/dev/null; then
    sed -i 's|^InputMethod\[.*|InputMethod[$e]=/usr/share/applications/org.fcitx.Fcitx5.desktop|' ~/.config/kwinrc
else
    printf '[Wayland]\nInputMethod[$e]=/usr/share/applications/org.fcitx.Fcitx5.desktop\n' >> ~/.config/kwinrc
fi
# 托盘亮度/电池（09-24）：容器 /sys 默认 ro → 亮度写 EROFS；powerdevil 也要人拉
sudo -n mount -o remount,rw /sys 2>/dev/null || true
PWDEV=$(ls /usr/lib/*/libexec/org_kde_powerdevil 2>/dev/null | head -1)
exec dbus-run-session -- bash -c 'fcitx5 -rd >/dev/null 2>&1; sleep 2; fcitx5-remote -c >/dev/null 2>&1; [ -n "$0" ] && ( sleep 5; WAYLAND_DISPLAY=wayland-0 nohup "$0" >/tmp/powerdevil-anland.log 2>&1 & ); exec startplasma-wayland' "$PWDEV"
