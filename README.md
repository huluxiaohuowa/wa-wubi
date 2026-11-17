# WA 五笔

WA 五笔是使用 Swift、InputMethodKit、AppKit 和 SwiftUI 开发的原生 macOS 86 五笔输入法。支持 macOS 13 及以上版本。官网和四键字练习在 [wa-wubi.fuluwa.top](https://wa-wubi.fuluwa.top/)。

## 安装

在 [GitHub Releases](https://github.com/huluxiaohuowa/wa-wubi/releases) 下载并打开 DMG，双击镜像里的「安装 WA 五笔」并点击「安装」。安装器将输入法放在当前用户的输入法目录，无需管理员权限。然后在「系统设置 → 键盘 → 文本输入 → 编辑」的简体中文类别添加 WA 五笔。首次安装后若列表还未刷新，注销再登录。

## 使用

| 按键 | 行为 |
| --- | --- |
| 空格、数字 1–5、分号、单引号 | 上屏当前候选、指定候选、第二项、第三项。默认排序下，单键时键名汉字位于第二候选，同键四连的全码中位于第一候选 |
| `-` / `=`、`[` / `]` | 候选翻页 |
| Shift | 轻按切换中英，组合键照常使用 |
| 空闲时按分号、输入大写字母 | 临时英文。分号模式也可输入 `2026-11-17` 或 `123.45` 后确认，得到中文日期或大写金额 |
| 反引号 | 临时拼音及五笔反查 |
| `z` + 空格 / `zz` | 重复上次输入 / 符号 |
| Control + 数字 / Control + Shift + 数字 | 候选置顶 / 隐藏 |
| Control + `=` / Control + `-` | 快捷加词 / 隐藏最近输入的候选，亦可使用选中文本 |
| Control + Option + Command + `]` | 词库管理 |
| Control + Option + T | 切换简体和繁体输出 |
| 按住 Control + Shift，松手 | 启用语音后，按住录音，松手转写到当前输入会话 |

从输入法菜单打开设置，可调整候选数量、主题、透明度、字号、横竖布局和标点。自动调序和调整范围可以分别设置，默认保护单键字与键名汉字。应用规则可为指定应用设置默认中英文。

### 词库与同步

- 本地可导入 `.scel`、Rime `.dict.yaml`、TXT、TSV 和 CSV。文本支持「词语 编码」或「编码 词语」，可带权重。也支持搜狗自定义短语的「编码,序号=词语」。只有词语时按 86 规则生成编码，生僻字缺码的词会计入跳过数。
- 搜狗拼音 SCEL 的词语通过单字全码重新计算为五笔，拼音索引不会成为五笔编码。
- 「词库 → 在线词库」可安装或更新计算机、医学和行政区划包。目录自动列出可安装词库及更新。下载安装优先直连官网或 GitHub，失败后依次尝试加速源，核对 SHA-256 后才安装或替换。
- 「同步」通过用户选择的 iCloud Drive 文件夹传输词库和输入偏好。两台 Mac 选同一位置。开启时可逐项合并（同一项优先较新修改、这台 Mac 或 iCloud），也可直接采用 iCloud 中的词库和设置。开启前会保存本机副本，关闭时可保留当前结果或恢复副本。开启后的后续冲突以较新修改为准，同一时间用版本与设备标识决出顺序。同步开关、文件夹选择和语音配置保存在本机。

### 语音

语音默认关闭。开启后可选择 Apple Speech、OpenAI、Groq、硅基流动或自定义 HTTPS 转写地址。自定义服务接收兼容 OpenAI 的 multipart `file`、`model`、`response_format`，返回 JSON `text`。

Apple Speech 在系统支持时优先设备端识别，也可强制仅设备端。主动选用云服务时，松手后音频发往选中的服务。密钥保存在本机钥匙串，录音文件使用后移除。

## 更新

可从输入法菜单手动检查，也可在设置中开启自动检查。更新优先通过 GitHub 获取，失败后轮试加速源。校验下载和签名后打开新版安装器。

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
