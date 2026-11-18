# WA 五笔 iOS 上架资料

## 商店页面

- 产品名称为 **WA 五笔**，类别为工具，首发本地化为简体中文。
- [海报墙](Poster-Wall.jpg) 供查看排版。上传使用 [六张独立 JPG](Upload/zh-Hans)，其中 iPhone 17 是 1206 × 2622，iPad 13 英寸是 2064 × 2752，iPhone Duo 内屏是 2853 × 2007。照片均来自模拟器里的真实输入、设置界面。
- [简体中文商店文案](Metadata/zh-Hans)、[App Review 说明](Metadata/review_information/notes.txt)、[TestFlight 测试说明](TestFlight.zh-Hans.txt)。
- [隐私政策](https://wa-wubi.fuluwa.top/privacy.html) 和 [支持入口](https://github.com/huluxiaohuowa/wa-wubi/issues)。
- 首个公开版本使用应用描述。后续公开版本把这一版的实际变化写入 `Metadata/zh-Hans/release_notes.txt`。

## 账号和签名

主 App 的 Bundle ID 为 `top.fuluwa.inputmethod.Wubi86.ios`，键盘扩展为 `top.fuluwa.inputmethod.Wubi86.ios.keyboard`。两者关联同一个 `group.top.fuluwa.inputmethod.Wubi86`。主 App 另启用 iCloud Documents，并关联已经用于 Mac 版的 `iCloud.top.fuluwa.inputmethod.Wubi86`。键盘扩展通过 App Group 读取本地共享数据。

`provision` 使用现有团队 Apple Distribution 证书，为两个目标查找或创建 App Store Connect 描述文件，校验 Bundle ID、App Group、现有 iCloud 容器和签名证书。验证通过的文件保存在团队 iCloud 的 `cert/wa-wubi/provisioningProfiles/`，并写入本机 Apple 配置的 `wa-wubi.provisioningProfiles.iosBase64` 和 `iosKeyboardBase64`。已存在的 Mac 描述文件继续独立保留。

App Store Connect 还需填写审核联系人、年龄分级、内容权利、价格与销售地区，并确认 App 隐私问卷。首发建议在已登录的真机上核对 iCloud 双端互通和系统键盘离线行为，再选定送审构建。

- 隐私清单已经随主 App 和键盘扩展打包。普通打字和本地词库可离线。核对 App 隐私问卷时，重点看用户主动发给搜狗的词库查询，以及主 App 可选语音服务的录音传输与留存。iCloud 数据存入用户自己的账户。根据签名成品和实际服务的数据处理选择 Apple 的标签。
- 上传版权声明之前，确认内置码表和在线词库的第三方许可。内置码表原文与 GPL/LGPL 文本、字体 OFL、Unicode 许可随包提供。在线词库保留发布源的来源与许可。
- 导出合规基于该构建使用系统 HTTPS、钥匙串以及哈希校验。若由于投放地区需要额外材料，在 App Store Connect 中按实际情况填写。
- 如选择中国大陆销售，以 App Store Connect 的「中国大陆的供应情况」和实际备案状态为准。网站本身的备案信息不能代替 App 的上架资料。

## 命令

需要 Node.js、Xcode、XcodeGen，以及上传阶段的 fastlane。当前 App Store 海报包含 Duo 内屏，使用支持 `APP_IPHONE_DUO` 截图类型的 fastlane 版本。

```sh
node script/release_ios.mjs check
node script/release_ios.mjs plan
node script/release_ios.mjs metadata
node script/release_ios.mjs provision
node script/release_ios.mjs check --online
node script/release_ios.mjs archive
node script/release_ios.mjs testflight
node script/release_ios.mjs testflight --internal-group='已存在的内部测试组'
node script/release_ios.mjs app-store
node script/release_ios.mjs app-store --automatic-release
```

- `check` 离线核对文案和所有截图。加 `--online` 后校验 Apple 记录与签名。
- `plan` 只查询 Apple 的版本及构建号。默认优先使用尚可编辑的版本，正式版发布后递增补丁版本。TestFlight 可继续使用更高的现有测试版本。同版本构建号取 Apple 和本地已用号码的最大值再加一。可用 `--version=X.Y.Z` 指定版本。
- `metadata` 把中国产品页文案和海报存入 App Store Connect 当前版本草稿，不上传二进制，也不送审。
- `archive` 生成签名归档和 IPA，写到 `~/dev/build/wa-wubi/ios-release/`。
- `testflight` 上传构建到 App Store Connect。指定内部组时，验证组存在，等待处理并发布到该内部组。
- `app-store` 上传签名构建、简体中文文案和海报，选择该构建后提交 App Review。默认由你在通过审核后手动发布。显式加 `--automatic-release` 时，审核通过后由 Apple 发布。这个流程可以直接送审，无需先向 TestFlight 测试组分发。

参考 [截图要求](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications/)、[上架及 TestFlight 流程](https://developer.apple.com/help/app-store-connect/get-started/app-store-connect-workflow/) 和 [键盘扩展审核规则](https://developer.apple.com/app-store/review/guidelines/#extensions)。
