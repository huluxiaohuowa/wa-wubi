# WA 五笔

WA 五笔是使用 Swift、InputMethodKit、AppKit 和 SwiftUI 开发的原生 macOS 86 五笔输入法。支持 macOS 13 及以上版本。官网和四键字练习在 [wa-wubi.fuluwa.top](https://wa-wubi.fuluwa.top/)。

## 安装

在 [GitHub Releases](https://github.com/huluxiaohuowa/wa-wubi/releases) 下载并打开 DMG，双击镜像里的「安装 WA 五笔」并点击「安装」。安装需管理员授权，输入法放在 `/Library/Input Methods`，供本机所有账号使用。每个账号可从菜单栏选择 WA 五笔，或先在「系统设置 → 键盘 → 文本输入 → 编辑」的简体中文类别中添加。

## 使用

| 按键 | 行为 |
| --- | --- |
| 空格、数字 1–9、分号、单引号 | 上屏当前候选、指定候选、第二项、第三项。单键时分号选择键名汉字所在项，默认排第二，和一级简码相同时合为首选。同键四连输入全码时，键名汉字排第一 |
| `-` / `=`、`[` / `]` | 候选翻页 |
| Enter | 可选择上屏候选或原样提交英文编码。默认提交英文编码 |
| Shift | 轻按切换中英，组合键照常使用 |
| 空闲时按分号、输入大写字母 | 临时英文。分号模式也可输入 `2026-11-17` 或 `123.45` 后确认，得到中文日期或大写金额 |
| 反引号 | 临时拼音及五笔反查 |
| `z` + 空格 / `zz` | 重复上次输入 / 符号 |
| Control + 数字 / Control + Shift + 数字 | 候选置顶 / 隐藏 |
| Control + `=` / Control + `-` | 快捷加词 / 隐藏最近输入的候选，亦可使用选中文本 |
| Control + Option + Command + `[` / `]` | 设置 / 用户词库 |
| Control + Option + T | 切换简体和繁体输出 |
| 按住 Control + Shift，松手 | 启用语音后，按住录音，松手转写到当前输入会话。可在「语音」里更改快捷键 |

从输入法菜单打开设置，可调整候选数量、主题、透明度、字号、横竖布局和标点。自动调序和调整范围可以分别设置，默认保护一级简码与键名汉字。应用规则可为指定应用设置默认中英文。

### 词库与同步

- 本地可导入 `.scel`、Rime `.dict.yaml`、TXT、TSV 和 CSV。文本支持「词语 编码」或「编码 词语」，可带权重。也支持搜狗自定义短语的「编码,序号=词语」。下载与导入均按 86 规则生成编码，重复词条优先使用用户指定或已有的编码。缺码的词会计入跳过数。
- 「词库 → 在线词库」按搜狗、Rime 和清华词库浏览或搜索，并可一键安装、检查更新。搜狗提供官方在线搜索，Rime 和清华词库优先直连，备用加速源和 SHA-256 校验由 WA 五笔处理。
- 「词库」可开启「从拆字输入自动加词」。删掉未选中的四码后，逐字上屏，组合出的编码与原编码相同时会加入用户词库。
- 「同步」默认将词库和偏好（包括语音和更新设置）保存到 iCloud Drive 的 `Wa-Wubi/state.json`。同一 Apple 账户的 Mac 共用这个文件。如改用自定义位置，两端需选同一文件夹。开启时可合并（优先较新修改、这台 Mac 或 iCloud），也可直接采用 iCloud 中的词库和设置。开启前会保存本机副本，关闭时可保留当前结果或恢复副本。日常同步会合并不同项的改动，同一项以最近修改为准。同步开关、文件夹选择、语音服务密钥和系统授权由每台 Mac 单独管理。

### 语音

语音默认关闭。开启后可选择 Apple Speech、OpenAI、Groq、硅基流动或自定义 HTTPS 转写地址。自定义服务接收兼容 OpenAI 的 multipart `file`、`model`、`response_format`，返回 JSON `text`。

Apple Speech 在系统支持时优先设备端识别，也可强制仅设备端。主动选用云服务时，松手后音频发往选中的服务。密钥保存在本机钥匙串，录音文件使用后移除。

菜单栏的 WA 五笔菜单也可切换五笔、拼音、混合方案与输简出繁，并打开设置、用户词库和关于页面。

## 更新

可从输入法菜单手动检查，或在设置中开启自动下载并安装。更新优先通过 GitHub 获取，失败后轮试加速源。下载校验通过后直接安装，macOS 可能请求管理员授权。

## 开发

```bash
swift test --scratch-path "$HOME/dev/build/wa-wubi/swift"
./script/build_and_run.sh --verify
./script/install_local.sh
```

macOS 26 或更新版本可能要求已公证的输入法参与系统注册。可以用 `WAWUBI_APP_PATH` 指向已签名并公证的 app，或从最终 DMG 安装。

本地发布由 `python3 script/release_local.py` 从已有 Apple 发布配置读取签名和公证参数。GitHub 的 **Sign and notarize** 可在 `v*` 标签上手动运行，安装包保存在 Actions 构建产物中。所需发布 Secrets 在 `apple-release` 环境中。

## 码表许可

[内置 86 五笔码表](https://github.com/rime/rime-wubi/tree/152a0d3f3efe40cae216d1e3b338242446848d07) 原样收录，保留作者署名和 [LGPL-3.0](Resources/LGPL-3.0.txt)、[GPL-3.0](Resources/GPL-3.0.txt) 原文。运行时由本项目 Swift 引擎加载文本码表。在线包的来源和许可见 [词库目录](https://github.com/huluxiaohuowa/wawubi-web/tree/main/dictionaries)。

候选窗使用随包分发的 WA Wubi Han 无衬线字体，基于 [Scriptwide Sans CJK v1.004](https://github.com/scriptwide-fonts/scriptwide-sans-cjk/releases/tag/v1.004)，覆盖内置码表和符号入口的所有字符。字体按随包附带的 SIL Open Font License 1.1 分发。
