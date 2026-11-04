#!/usr/bin/env python3
"""Write hand-polished translations for the 47 full concat keys.

Each entry matches a key from concat_full_keys.json by a distinctive prefix
(full keys contain the joined piece text, which is stable), then writes
i18n_work/fragments/zz_concat_full.json. Fails loudly if any key is unmatched
or any translation matches nothing — the full keys are what actually displays,
so every one of the 47 must land.
"""

import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

T = [
    ("One branch of each segment plays per round.",
     "每个分段每回合播放其中一条路径。在下方为事件标注路径，即可让它在该路径上播放；未标注的事件始终播放。"),
    ("Add this round's funscript to see what a full pass is worth",
     "添加本回合的 Funscript，才能看清一次完整行程的价值——没有它，目标值只能是猜测。"),
    ("A button the player can press during a round to end the run early",
     "玩家在回合中可以按下、用来提前结束本次流程的按钮（“我高潮了”——F 键）。它会在结束画面之前播放一段事后安抚序列（例如一段渐趋平缓的过场剧情 → 一个温和的回合）。自带事后安抚链接的回合（拖动其右侧的玫瑰色手柄）会提供该按钮并播放那段链接。在下方选定一个默认项，其余回合也会提供它。两者都没有的回合则没有按钮。事后安抚位于主图之外，终止于一个没有出口的节点。"),
    ("Plays under storyboards, shops, checkpoints and forks",
     "在过场剧情、商店、检查点和分支下播放——即一切非回合的内容。场景的音乐或过场剧情自带的音乐会覆盖它。多首曲目随机洗牌；回合期间暂停，之后从断点继续播放。"),
    ("Declare a counter to give it bounds",
     "声明计数器即可为其设定边界：弹药停在 0，兴奋度停在 100。无论在何处写入计数器——节点、分支选项、物品——钳制都会生效，因此旅程可以自由加减而不会越界。你从未声明过的计数器，行为与从前完全一致：不设边界、也不显示。"),
    ("Flags remember that something happened",
     "标记记录「某件事发生过」——门被打开过、Boss 被放过——分支、循环和物品稍后会读取它们。声明一个标记后，所有需要选标记的地方都会列出它，名字不会重复输入，也不会输错。你从未声明的标记照旧工作。"),
    ("Random rolls only from the effects you add below",
     "只从你在下方添加的效果中随机抽取——请至少添加一个，否则该回合不施加任何效果。"),
    ("This shop draws its stock at random",
     "本商店随机抽取库存——若某次光顾没有抽到此物品，此货位便会空置。"),
    ("The device you own. Decides which multi-axis curses",
     "你拥有的设备。决定会出现哪些多轴诅咒与物品、是否提供自动旋转，确保你不会遇到感受不到的效果。它不会改变实际发送的内容。"),
    ("Counting as Stroke only: the stroke isn't set to a serial device",
     "仅按行程计算：行程未设置为串口设备，而只有串口承载其余各轴。要使用它，请在「设备路由」中把「串口」设为抽插设备。"),
    ("Twists with the stroke on content that has no twist script",
     "在内容没有自带旋转脚本时，随行程一同旋转——适用于带旋转轴的串口设备（SR6，或装有旋转扩展件的 OSR2）。若内容自带旋转脚本，则始终播放脚本旋转。其幅度受上方旋转范围缩放，区间很窄时连 Strong 也会变得轻微。"),
    ("Red-green and blue-yellow safe swap the colours",
     "「红绿色盲安全」与「蓝黄色盲安全」会把承载含义的颜色（成功或失败、诅咒或赐福、强度高低）换成在该类色盲下仍能彼此区分的配色。「高对比度」面向低视力玩家：文字更白、边缘更亮、光晕更少。预览会立即变化；每个界面在打开时采用新配色。"),
    ("Slows the Flicker effect to under three dark flashes",
     "把闪烁效果放缓到每秒少于三次暗闪、并把亮度调得更柔和，同时让原本会骤然出现在屏幕上的 Boss 提示改为淡入。适合对闪光敏感的玩家。从下一个效果或提示开始生效。"),
    ("Switches the whole interface at once",
     "一次性切换整个界面的语言——菜单、编辑器、提示与游戏内文本。旅程内部的名称、标签与文案始终按你的原始创作显示。"),
    ("Direct Handy mode streams motion through Handy's cloud service",
     "Direct Handy 模式通过 Handy 的云服务（handyfeeling.com）传输动作，需要联网。要求 Handy 固件 4+。行程修改类物品、诅咒、Boss 效果以及你的行程范围都会作用于设备；回合中途做出的更改会在零点几秒后生效。"),
    ("Output levels for restim: Volume, Alpha/Beta, Carrier",
     "Restim 的输出强度：Volume、Alpha/Beta、Carrier、Pulse 与 Vibration。仅在连接了 e-stim 设备时才需要。"),
    ("A pattern plays on your device and draws here",
     "设备会播放一个模式，同时在此处画出同样的节拍：一次长而慢的行程、三次快速抽动，然后停顿。对上其中任意一个即可——三者的感觉截然不同，所以如果你在节拍条还在上升时就感到那几下快的，说明偏差还很大。调整延迟，直到设备与节拍条一致。"),
    ("One number can't be right everywhere: a stroker's travel time",
     "没有一个数值能处处适用：抽插设备的行程时间随距离与速度增长，所以快速的全行程段落总会比慢速短行程段落滞后更多。请先用这个模式校准出一个干净的起点，游玩中若密集段落感觉偏晚再微调。\n在 Handy 上，修改延迟会重新建立数据流——你感到的那一下小顿挫来自这里，而不是同步出了偏差。"),
    ("A target, not a cut: rounds are built from whole stretches",
     "这是目标时长，而非硬性切分：回合由脚本中完整的段落构成，强度越高目标越短，因此实际时长会有浮动。当强度变化或脚本停顿（超过 5 秒——若仍低于下限手柄则为 20 秒）时，回合可能提前结束；视频的最后一个回合也可能较短。"),
    ("Step to the next branch, and to the next alternative line",
     "前进到下一条路径；若某条提示带有备选行，则前进到下一条备选。连续点击即可遍历所有组合并回到起点。只影响预览。"),
    ("CTRL+wheel zooms · wheel scrolls the lanes",
     "CTRL+滚轮缩放 · 滚轮滚动轨道 · 中键拖动平移 · 右键设置胜利跳过点。拖动方块可移动它，拖动右边缘可调整长度。"),
    ("The boss's colour: the bar, its brackets",
     "Boss 的颜色：血条、血条括号、光晕以及其上方的名字。单个阶段仍可为该阶段覆盖此颜色。各 STANCE 保留自己的颜色——玩家记住一次之后，在任何 Boss 身上都能读出来，所以一场遭遇战不能重新定义 GUARDING。"),
    ("Where the name and bar sit down the screen: 0 is the top edge, 1 the bottom. The whole block",
     "名称与血条在屏幕纵向上的位置：0 是上边缘，1 是下边缘。整个区块一起移动，且不会滑出两端——因此出场立绘想占据画面顶部也没问题。"),
    ("What drains the bar. TIME is the clock read backwards",
     "决定血条如何被消耗。TIME 是把时钟倒过来读——与普通进度条显示的是同一个数字。SCORE 把它朝向玩家，玩家得分时血条才会被清空。单是清空它不起任何作用：在 Score 上挂一条规则来决定之后发生什么。"),
    ("Score that empties the bar. What is achievable",
     "清空血条所需的分数。可达成程度完全取决于回合，请参照你自己实际游玩这一局时的得分来调校。"),
    ("How many passes the player gets. ONE plays the round once",
     "玩家可以获得多少次机会。ONE 表示只播放一次回合就继续，无论血条到达了哪里。次数更多时它就变成一场战斗：一次打完 Boss 仍然站着的，就重打本回合，并保留已造成的伤害。"),
    ("Raises this run flag when the round ends this way",
     "回合以此方式结束时置位本局标记，以便后续的分支或回合询问这场战斗的结果。越过 Boss 继续前进，不再等于玩家击败了它。"),
    ("Renaming a branch does NOT retag the events",
     "重命名路径不会重新标注已在其中的事件——它们会脱落并变为始终播放，所以请从每个事件的「路径」字段重新标注。"),
    ("How an ANIMATED cue composites.",
     "动画提示的合成方式。NORMAL 按原样绘制片段。ADD 与 SCREEN 会把黑色去掉——这正是让闪光或光晕贴在画面上、而不是显示成一块矩形的原因——适合用在黑底素材上。SCREEN 目前的渲染效果与 ADD 相同。静态图片忽略此项。"),
    ("Where the line sits down the screen: 0 is the top edge, 1 the bottom. Tuck it under a portrait",
     "字幕行在屏幕纵向上的位置：0 是上边缘，1 是下边缘。可以把它藏到立绘下方、抬到血条之上，或居中——预览中会显示血条，你可以对着实际画面摆放。"),
    ("Another version of this one, picked at random",
     "本条的另一个版本，回合开始时随机选取。原始版本仍在候选之列——两个备选意味着三种可能的结果。"),
    ("Jumps the clip forward the moment the boss goes down",
     "在 Boss 倒下的瞬间向前跳转片段，让胜利更快抵达结局。仅限向前——向后跳转会重放遭遇战已经触发过的事件。"),
    ("FROM THE END is usually what you want",
     "通常你想要的是「从结尾」：跳到最后 10 秒，这样即使你重新剪过视频它也依然有效；而从开头量起的位置则不然。"),
    ("Health the boss wins back for every second",
     "游戏暂停期间 Boss 每秒赢回的生命值。0 表示关闭。暂停是玩家唯一真正能自己做的减速——分数来自脚本，而不是玩家——所以正是这一项让中途离开战斗有代价。"),
    ("How much of the bar the boss recovers before each replay",
     "每次重播前 Boss 回复的血量比例。0 表示关闭，战斗就是纯粹的消耗战。任何更高的数值都会让重播变成层层加码而非原地磨血——设为 100% 时，每次尝试 Boss 都以满血开始。"),
    ("Sets the target to one full pass",
     "把目标设为一次完整行程，战斗便在本回合内决出胜负。要多打几次才倒的 Boss 就设高一些；很快倒下、把片段其余部分留作余韵的 Boss 就设低一些。"),
    ("How much damage lands while this window is open",
     "此窗口开启期间造成的伤害量，以及血条上显示的词。RECOVERING 会让血条倒退——Boss 在自我治疗。ATTACKING 用于写入回合自身 Funscript、而非放在攻击轨道上的招式：没有任何机制能检测到它，所以在这里标注：Boss 在此期间不受伤害，修正物品也无法切入，与攻击轨道上的情形完全一致。攻击轨道上的攻击则无需此项，因为它两者本就兼具。同一时间只能有一个 STANCE 生效，因此它们不得重叠。"),
    ("How the cue arrives, over the fade-in time below",
     "提示出现的方式，时长为下方的淡入时间。FADE 单纯缓入。FLASH 立即出现并忽略该时长——就是出招预告的样子。POP 以略大的尺寸冲入再回稳。RISE 轻轻上浮，适合台词。SLIDE 从指定边缘进入——通常是提示离得最近的那个边缘，避免它横穿整个画面。"),
    ("For a voiced line. The music steps back",
     "用于配音台词。这段音频播放时音乐会自动退让，播完后立刻恢复——无论是哪首音乐：旅程的、场景的，还是这段过场剧情自带的。音效请保持关闭：闷响或枪声应当落在音乐之上，而不是取代音乐。"),
    ("Balance report: dead fork paths",
     "平衡报告：死路分支、买不起的价钱、拿不到的物品、未设置的标记，以及极少被经过的内容"),
    ("Heatmap: tint the graph by how often",
     "热力图：按模拟流程经过各路径的频率给图着色（红色/粗线 = 极为常见，浅绿色/细线 = 极为罕见）。进行结构性修改后自动关闭。"),
    ("Reserves this spot for one item. Pinning does NOT",
     "此货位为某一件物品预留。固定并不会让商店一定上架它——上不上架仍由商店决定。在随机池模式下，商店随机抽取库存，被固定的物品只有恰好被抽中才会出现；要让它必定上架，请把它加入商店的「保底列表」。在固定模式下，列表中的每件物品始终都会提供，固定必定生效。"),
    ("Plays a slow, full-range stroke on your stroker",
     "在你的抽插设备上播放一次慢速的全行程抽动，同时在屏幕上画出同样的行程，通过对比两者来设定延迟，而不用凭感觉猜。"),
    ("Stroke rate: runs faster the faster the script strokes",
     "行程频率：脚本抽动得越快它运行得越快，脚本停住时它也停止。vibe1 / vibe2：速度由回合的震动脚本设定。"),
    ("The slowest it runs while the script is moving",
     "脚本运动期间它运行的下限（部分设备过慢会卡死），以及它运行的上限。脚本停住时它仍会停止。"),
    ("Positive means the device acts LATER, negative means earlier",
     "正值表示设备动作更晚，负值表示更早。如果设备比节拍条更晚到顶，就用负值。"),
    ("Bring the clips from Stash up to date",
     "把来自 Stash 的片段同步到最新：加入新场景，标签跟随 Stash，场景已消失的片段会被标记。"),
]


def main():
    fulls = json.loads((ROOT / "i18n_work" / "concat_full_keys.json").read_text(encoding="utf-8"))
    frag = {}
    used = set()
    for prefix, zh in T:
        matches = [k for k in fulls if k.startswith(prefix)]
        if len(matches) != 1:
            print(f"FAIL: prefix {prefix!r} matched {len(matches)} keys")
            sys.exit(1)
        frag[matches[0]] = zh
        used.add(matches[0])
    unmatched = [k for k in fulls if k not in used]
    if unmatched:
        for k in unmatched:
            print(f"FAIL: key not covered by any translation: {k[:80]!r}")
        sys.exit(1)
    out = ROOT / "i18n_work" / "fragments" / "zz_concat_full.json"
    out.write_text(json.dumps(frag, indent=1, ensure_ascii=False), encoding="utf-8")
    print(f"wrote {out.name}: {len(frag)} hand-polished full-key translations (all {len(fulls)} keys covered)")


if __name__ == "__main__":
    main()
