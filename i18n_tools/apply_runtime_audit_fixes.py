#!/usr/bin/env python3
"""Third-pass translations: keys surfaced by the runtime tree-walk audit and the
fixed coverage filter (was: two-word/one-word ASCII labels skipped as identifiers).
"""

import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

T = {
    # ── builder side-panel field labels (helper-harvested, runtime lookup) ──
    "ADD NODE": "添加节点",
    "API key": "API 密钥",
    "Anchor": "锚点",
    "Attempts": "尝试次数",
    "BASE PROMPT": "基础提示词",
    "Bar colour": "色条颜色",
    "CARD IMAGE": "卡片图片",
    "COINS AWARDED": "奖励金币",
    "CONTINUES TO": "继续前往",
    "COVER IMAGE": "封面图片",
    "Clip tags": "片段标签",
    "Connect cancelled.": "已取消连接。",
    "DEFAULT IMAGE": "默认图片",
    "DELETE ANYWAY": "仍要删除",
    "DIALOGUE LINES": "台词行",
    "EXIT WHEN": "退出条件",
    "Ease in": "缓入",
    "Ease out": "缓出",
    "Effect-round chance": "效果回合概率",
    "Entrance": "出场方式",
    "Expression": "表情",
    "FORCED MODIFIERS": "强制修正",
    "FORK CHOICES": "分支选项",
    "Factor": "系数",
    "IMAGE FIT": "图片适配",
    "IMPORTING CLIPS": "正在导入片段",
    "ITEM SELECTION": "物品选择",
    "JOURNEY NAME": "旅程名称",
    "JOURNEY PREVIEW": "旅程预览",
    "LAST SCORE": "上次分数",
    "LEADS TO": "通往",
    "Length mode": "时长模式",
    "Line Y": "台词行 Y",
    "MAIN FUNSCRIPT": "主 Funscript",
    "MAP BACKDROPS": "地图背景",
    "Max": "上限",
    "Measured": "实测",
    "Min": "下限",
    "Nudge X": "微调 X",
    "Nudge Y": "微调 Y",
    "Outline": "描边",
    "PRICE MULTIPLIER": "价格倍率",
    "Pasted note.": "已粘贴备注。",
    "Pitch tilt": "俯仰倾斜",
    "Plate": "衬底",
    "Position": "位置",
    "Presets": "预设",
    "REACHED IN": "到达率",
    "REMOVES ITEMS": "移除物品",
    "REPLAY FROM": "重播起点",
    "REQUIRED FLAG": "所需标记",
    "RESOLVED BY": "裁定方式",
    "ROUND NAME": "回合名称",
    "Redo.": "已重做。",
    "Roll tilt": "侧倾倾斜",
    "Round count": "回合数",
    "SEED ITEMS": "初始物品",
    "SETTING NAME": "场景名称",
    "SHOP TITLE": "商店标题",
    # ── builder graph node buttons & side headers (const arrays) ──
    "▶ ROUND": "▶ 回合",
    "⑂ FORK": "⑂ 分支",
    "◆ SHOP": "◆ 商店",
    "◈ STORY": "◈ 过场剧情",
    "⏱  AUTO-ADVANCE  ▸": "⏱  自动前进  ▸",
    "⚑  FLAGS  ▸": "⚑  标记  ▸",
    "🏁  AFTERCARE  ▸": "🏁  事后安抚  ▸",
    "🔢  COUNTERS  ▸": "🔢  计数器  ▸",
    "🗺  PLAYER MAP  ▸": "🗺  玩家地图  ▸",
    # ── options: restim axis groups & channel labels (const array) ──
    "MASTER": "主控",
    "POSITION": "位置",
    "CARRIER": "载波",
    "PULSE": "脉冲",
    "VIBRATION 1": "震动 1",
    "VIBRATION 2": "震动 2",
    "Volume": "音量",
    "Alpha ← stroke": "Alpha ← 行程",
    "Beta ← surge": "Beta ← 前后",
    "Carrier freq ← twist": "载波频率 ← 旋转",
    "Pulse freq ← pitch": "脉冲频率 ← 俯仰",
    "Pulse width": "脉冲宽度",
    "Pulse interval random": "脉冲间隔随机",
    "Pulse rise time": "脉冲上升时间",
    "Vib1 freq ← sway": "震动1 频率 ← 左右",
    "Vib1 strength ← roll": "震动1 强度 ← 侧倾",
    "Vib1 random": "震动1 随机",
    "Vib1 L/R bias": "震动1 左/右偏置",
    "Vib1 up/down bias": "震动1 上/下偏置",
    "Vib2 freq": "震动2 频率",
    "Vib2 strength": "震动2 强度",
    "Vib2 random": "震动2 随机",
    "Vib2 L/R bias": "震动2 左/右偏置",
    "Vib2 up/down bias": "震动2 上/下偏置",
    # device-axis display names as formatted "Name (id)" at runtime
    "Surge (L1)": "前后 (L1)",
    "Sway (L2)": "左右 (L2)",
    "Twist (R0)": "旋转 (R0)",
    "Roll (R1)": "侧倾 (R1)",
    "Pitch (R2)": "俯仰 (R2)",
    # ── options misc ──
    "ON": "开",
    "OFF": "关",
    "Path": "路径",
    "Server": "服务器",
    "Stroke only": "仅行程",
    "! Battery low": "！电量低",
    "i Scanning…": "i 扫描中…",
    "✕ Can't reach Stash": "✕ 无法连接 Stash",
    "☠  CURSE": "☠  诅咒",
    "✦  BOON": "✦  赐福",
    "▸  SHOW E-STIM LEVELS (%d)": "▸  显示 E-STIM 电平 (%d)",
    "▾  HIDE E-STIM LEVELS": "▾  隐藏 E-STIM 电平",
    "%s strokes/s": "%s 次行程/秒",
    # ── timing delay hints (per-piece tr(), call-time concat) ──
    "Timing offset for Buttplug / Intiface devices, in milliseconds. Positive = the device ":
        "Buttplug / Intiface 设备的时序偏移，单位毫秒。正值 = 设备更晚动作，",
    "fires later, negative = earlier. Adjust until the device lines up with the video. ":
        "负值 = 更早。请调整到设备与视频对齐为止。",
    "Can also be nudged live during play.": "游玩过程中也可以实时微调。",
    "Timing offset for the serial (T-code) stroker, in milliseconds. Positive = the device ":
        "串口（T-code）抽插设备的时序偏移，单位毫秒。正值 = 设备更晚动作，",
    "Adjust until the stroker lines up with the video. ":
        "请调整到抽插设备与视频对齐为止。",
    "Timing offset for the Handy over WiFi, in milliseconds. Positive = the device fires ":
        "通过 WiFi 连接的 Handy 的时序偏移，单位毫秒。正值 = 设备更晚动作，",
    "later, negative = earlier.": "负值 = 更早。",
    # ── oscillate / serial smoothing hints (per-piece tr()) ──
    "How fast the script has to stroke, in strokes per second, for an oscillating device to reach ":
        "摆动设备达到最大速度上限所需的脚本行程速度，单位为每秒行程次数。",
    "its max speed limit. Slower strokes run it slower, down to its min limit, and shallow strokes ":
        "更慢的行程会让它跑得更慢，下限为最小限制；浅行程的计入权重也低于完整行程。",
    "count for less than full ones. Lower it if the machine rarely gets going; raise it if it's ":
        "设备很少达到全速就调低它；",
    "always flat out.": "总是全速跑满就调高它。",
    "How smoothly motion is streamed to a T-code stroker (OSR2 / SR6). Higher = smoother, ":
        "串流到 T-code 抽插设备（OSR2 / SR6）的动作平滑程度。数值越高 = 越平滑流畅；",
    "more fluid strokes; lower = snappier but can look steppy on fast sections. The best ":
        "越低 = 响应更干脆，但快速段落可能出现顿挫感。最佳",
    "value depends on your device — raise it if the motion looks choppy, lower it if it ":
        "数值取决于你的设备——画面看起来卡顿就调高，",
    "feels laggy or soft.": "感觉延迟或绵软就调低。",
    "Runs at the slowest limit while the script moves and stops when it holds; reaches the max ":
        "脚本运动期间以最低限制运行，停住时停止；达到最大限制的速度为 ",
    "limit at %s (FULL SPEED AT, under OSCILLATING DEVICES).":
        "（即 FULL SPEED AT，位于「摆动设备」下）。",
    # ── randomizer ──
    "Aim: 60–180 s per round": "目标：每回合 60–180 秒",
    "Hard rounds aim shorter · 50%": "困难回合目标更短 · 50%",
    "No clips yet — add videos (their .funscript is paired automatically).":
        "还没有片段——先添加视频（.funscript 会自动配对）。",
    # ── journey count (after plural restructure) ──
    "%d JOURNEY": "%d 个旅程",
    "%d JOURNEYS": "%d 个旅程",
    "AXIS ": "轴 ",
}


def main():
    mp = ROOT / "i18n_work" / "manual_keys.json"
    m = json.loads(mp.read_text(encoding="utf-8"))
    added, updated = [], []
    for k, v in T.items():
        if k not in m:
            added.append(k)
        elif m[k] != v:
            updated.append(k)
        m[k] = v
    mp.write_text(json.dumps(m, indent=1, ensure_ascii=False), encoding="utf-8")
    print(f"manual: +{len(added)} new, ~{len(updated)} updated, total {len(m)}")


if __name__ == "__main__":
    main()
