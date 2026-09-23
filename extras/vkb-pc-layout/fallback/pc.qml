// Copyright (C) 2026 Yizhou — piano-patch full-size PC layout (v7)
// SPDX-License-Identifier: GPL-3.0-or-later
// 全尺寸 PC 布局。进入/退出：主键盘 "PC" 键（Qt.Key_F13 + Keyboard.qml pcMode 补丁）。
// v7：combo 通道扩展到全键盘（Ctrl+数字/Tab/Enter/方向/功能键均走 pc-keyd uinput）；
//     ⇧+数字/符号输出上档字符（1→! 2→@ ...）；⇧+Tab/Enter/方向等路由 daemon 带 shift；
//     自定义 ModeButton 取代 ModeKey（Breeze 样式 modeKey 40px 全大写、key 60px 混排
//     不一致——统一成 60px MixedCase，标签一律首字母大写）。

import QtQuick
import QtQuick.Layouts
import QtQuick.VirtualKeyboard
import QtQuick.VirtualKeyboard.Components

KeyboardLayout {
    id: pcRoot
    keyWeight: 100
    inputMode: InputEngine.InputMode.Latin

    function combo(upperKey, mods) {
        var x = new XMLHttpRequest()
        x.open("GET", "http://127.0.0.1:48222/combo?key=" + upperKey + "&mods=" + mods)
        x.send()
    }

    function modsNow() {
        var mods = []
        if (ctrlKey.mode) mods.push("ctrl")
        if (altKey.mode) mods.push("alt")
        if (shiftKey2.mode) mods.push("shift")
        return mods.join(",")
    }

    function releaseModes() {
        ctrlKey.mode = false
        altKey.mode = false
        shiftKey2.mode = false
    }

    // 粘滞修饰键：普通 Key 面板（60px、MixedCase），点亮=高亮底+右上圆点
    component ModeButton: Key {
        property bool mode
        key: Qt.Key_unknown
        functionKey: true
        noKeyEvent: true
        highlighted: mode
        smallText: mode ? "\u25cf" : ""
        onClicked: mode = !mode
    }

    // 字母键：Ctrl/Alt 走 uinput；⇧ 本地转大写（不走 daemon）
    component PCKeep: Key {
        property int upperKey
        readonly property bool modActive: ctrlKey.mode || altKey.mode
        noKeyEvent: modActive
        // BaseKey.uppercased 默认跟 InputContext.uppercase（Konsole 恒真 bug 根源），
        // 本页大小写只认 ⇧
        uppercased: shiftKey2.mode
        key: shiftKey2.mode ? upperKey : (upperKey + 32)
        text: shiftKey2.mode ? String.fromCharCode(upperKey) : String.fromCharCode(upperKey + 32)
        onClicked: {
            if (modActive) {
                pcRoot.combo(upperKey, pcRoot.modsNow())
                pcRoot.releaseModes()
            } else {
                shiftKey2.mode = false
            }
        }
    }

    // 全键 combo 通道：comboCode=Qt 键码；shiftText=⇧ 本地输出字符（打印键）；
    // routeShift=true 表示 ⇧ 单独按下也要走 daemon（Tab/Enter/方向/导航，
    // 这些没有"上档字符"概念，⇧ 是修饰语义如 ⇧+Tab=Backtab）
    component PCKey: Key {
        property int comboCode: Qt.Key_unknown
        property string baseText: ""
        property string shiftText: ""
        property bool routeShift: false
        readonly property bool modActive: ctrlKey.mode || altKey.mode || (routeShift && shiftKey2.mode)
        functionKey: true
        noKeyEvent: modActive
        uppercased: false
        key: comboCode
        text: shiftKey2.mode && shiftText.length > 0 ? shiftText : baseText
        onClicked: {
            if (modActive) {
                pcRoot.combo(comboCode, pcRoot.modsNow())
                pcRoot.releaseModes()
            } else {
                shiftKey2.mode = false
            }
        }
    }

    KeyboardRow {
        PCKey { comboCode: Qt.Key_Escape; displayText: "Esc" }
        PCKey { comboCode: Qt.Key_F1; displayText: "F1" }
        PCKey { comboCode: Qt.Key_F2; displayText: "F2" }
        PCKey { comboCode: Qt.Key_F3; displayText: "F3" }
        PCKey { comboCode: Qt.Key_F4; displayText: "F4" }
        PCKey { comboCode: Qt.Key_F5; displayText: "F5" }
        PCKey { comboCode: Qt.Key_F6; displayText: "F6" }
        PCKey { comboCode: Qt.Key_F7; displayText: "F7" }
        PCKey { comboCode: Qt.Key_F8; displayText: "F8" }
        PCKey { comboCode: Qt.Key_F9; displayText: "F9" }
        PCKey { comboCode: Qt.Key_F10; displayText: "F10" }
        PCKey { comboCode: Qt.Key_F11; displayText: "F11" }
        PCKey { comboCode: Qt.Key_F12; displayText: "F12" }
    }
    KeyboardRow {
        PCKey { comboCode: Qt.Key_QuoteLeft; baseText: "`"; shiftText: "~"; displayText: "`" }
        PCKey { comboCode: Qt.Key_1; baseText: "1"; shiftText: "!"; displayText: "1" }
        PCKey { comboCode: Qt.Key_2; baseText: "2"; shiftText: "@"; displayText: "2" }
        PCKey { comboCode: Qt.Key_3; baseText: "3"; shiftText: "#"; displayText: "3" }
        PCKey { comboCode: Qt.Key_4; baseText: "4"; shiftText: "$"; displayText: "4" }
        PCKey { comboCode: Qt.Key_5; baseText: "5"; shiftText: "%"; displayText: "5" }
        PCKey { comboCode: Qt.Key_6; baseText: "6"; shiftText: "^"; displayText: "6" }
        PCKey { comboCode: Qt.Key_7; baseText: "7"; shiftText: "&"; displayText: "7" }
        PCKey { comboCode: Qt.Key_8; baseText: "8"; shiftText: "*"; displayText: "8" }
        PCKey { comboCode: Qt.Key_9; baseText: "9"; shiftText: "("; displayText: "9" }
        PCKey { comboCode: Qt.Key_0; baseText: "0"; shiftText: ")"; displayText: "0" }
        PCKey { comboCode: Qt.Key_Minus; baseText: "-"; shiftText: "_"; displayText: "-" }
        PCKey { comboCode: Qt.Key_Equal; baseText: "="; shiftText: "+"; displayText: "=" }
        PCKey { comboCode: Qt.Key_Backspace; weight: 150; routeShift: true;
                displayText: "\u232B" }
        PCKey { comboCode: Qt.Key_Insert; displayText: "Ins"; routeShift: true }
        PCKey { comboCode: Qt.Key_Delete; displayText: "Del"; routeShift: true }
    }
    KeyboardRow {
        PCKey { comboCode: Qt.Key_Tab; displayText: "Tab"; routeShift: true; weight: 150 }
        PCKeep { upperKey: Qt.Key_Q }
        PCKeep { upperKey: Qt.Key_W }
        PCKeep { upperKey: Qt.Key_E }
        PCKeep { upperKey: Qt.Key_R }
        PCKeep { upperKey: Qt.Key_T }
        PCKeep { upperKey: Qt.Key_Y }
        PCKeep { upperKey: Qt.Key_U }
        PCKeep { upperKey: Qt.Key_I }
        PCKeep { upperKey: Qt.Key_O }
        PCKeep { upperKey: Qt.Key_P }
        PCKey { comboCode: Qt.Key_BracketLeft; baseText: "["; shiftText: "{"; displayText: "[" }
        PCKey { comboCode: Qt.Key_BracketRight; baseText: "]"; shiftText: "}"; displayText: "]" }
        PCKey { comboCode: Qt.Key_Backslash; baseText: "\\"; shiftText: "|"; displayText: "\\" }
        PCKey { comboCode: Qt.Key_Home; displayText: "Home"; routeShift: true }
        PCKey { comboCode: Qt.Key_PageUp; displayText: "Pgup"; routeShift: true }
    }
    KeyboardRow {
        ModeButton {
            id: shiftKey2
            displayText: "Shift"
            weight: 150
        }
        PCKeep { upperKey: Qt.Key_A }
        PCKeep { upperKey: Qt.Key_S }
        PCKeep { upperKey: Qt.Key_D }
        PCKeep { upperKey: Qt.Key_F }
        PCKeep { upperKey: Qt.Key_G }
        PCKeep { upperKey: Qt.Key_H }
        PCKeep { upperKey: Qt.Key_J }
        PCKeep { upperKey: Qt.Key_K }
        PCKeep { upperKey: Qt.Key_L }
        PCKey { comboCode: Qt.Key_Semicolon; baseText: ";"; shiftText: ":"; displayText: ";" }
        PCKey { comboCode: Qt.Key_Apostrophe; baseText: "'"; shiftText: "\""; displayText: "'" }
        PCKey { comboCode: Qt.Key_Return; weight: 150; routeShift: true;
                displayText: "Enter" }
        PCKey { comboCode: Qt.Key_End; displayText: "End"; routeShift: true }
        PCKey { comboCode: Qt.Key_PageDown; displayText: "Pgdn"; routeShift: true }
    }
    KeyboardRow {
        ModeButton {
            id: ctrlKey
            displayText: "Ctrl"
            weight: 125
        }
        PCKeep { upperKey: Qt.Key_Z }
        PCKeep { upperKey: Qt.Key_X }
        PCKeep { upperKey: Qt.Key_C }
        PCKeep { upperKey: Qt.Key_V }
        PCKeep { upperKey: Qt.Key_B }
        PCKeep { upperKey: Qt.Key_N }
        PCKeep { upperKey: Qt.Key_M }
        PCKey { comboCode: Qt.Key_Comma; baseText: ","; shiftText: "<"; displayText: "," }
        PCKey { comboCode: Qt.Key_Period; baseText: "."; shiftText: ">"; displayText: "." }
        PCKey { comboCode: Qt.Key_Slash; baseText: "/"; shiftText: "?"; displayText: "/" }
        PCKey { comboCode: Qt.Key_Up; displayText: "\u2191"; routeShift: true }
    }
    KeyboardRow {
        ModeButton {
            id: altKey
            displayText: "Alt"
            weight: 125
        }
        PCKey { comboCode: Qt.Key_F13; displayText: "PC"; weight: 125 }
        SpaceKey { weight: 500 }
        PCKey { comboCode: Qt.Key_Menu; displayText: "Menu"; weight: 125 }
        PCKey { comboCode: Qt.Key_Left; displayText: "\u2190"; routeShift: true }
        PCKey { comboCode: Qt.Key_Down; displayText: "\u2193"; routeShift: true }
        PCKey { comboCode: Qt.Key_Right; displayText: "\u2192"; routeShift: true }
    }
}
