# 曲谱阅读器 · iPad Sheet Music Reader

**在电脑整理谱库，在 iPad 随身看谱。**

面向练习、排练和演出的本地曲谱阅读项目，使用 Flutter / Dart 开发。Windows 管理文件夹和曲单，iPad 通过同一局域网连接电脑，按需下载曲谱，离线阅读并保存批注。

Local-first sheet music reading for Windows and iPad: folder libraries, PDF/image viewing, annotations, set lists, and selective offline downloads over your own LAN.

[使用指南](docs/USER_GUIDE.md) · [安装与构建](docs/BUILDING.md) · [常见问题](docs/FAQ.md) · [架构说明](docs/ARCHITECTURE.md) · [版本记录](CHANGELOG.md) · [构建下载](https://github.com/NonoKing123456/ipad-sheet-music-reader/releases)

> 当前源码候选版本：`0.8.10+30`，已完成靠框边文字控制点、统一色点、新文字短框自动增长及新阅读会话默认第一页。此前 Windows 与 iPad `0.8.10+29` 已交付；本轮两端候选包的构建与交付状态以对应记录及 Release 的 `build-info.txt` 为准，尚未完成新版本真机验证。仓库包含 Flutter 应用、Windows 与 iOS 原生工程、三个 Dart 核心包、可移植测试和构建工具。项目不附带曲谱资源。

## 能做什么

| 场景 | 功能 |
| --- | --- |
| 整理曲谱 | 多个谱库文件夹，保留原有层级，按文件名和相对路径搜索 |
| 文件阅读 | PDF、JPG / JPEG、PNG、WebP；图片作为单页曲谱 |
| 电脑看谱 | 单页、双页、连续阅读；缩放、翻页和页码定位 |
| iPad 看谱 | 整页适配、点按边缘翻页、手势缩放与移动、可收起工具栏 |
| 做笔记 | 画笔、荧光笔、橡皮和谱面原位文字批注，选色、拖动及旋转吸附，支持撤销与重做 |
| 排练与演出 | 创建、排序曲单，按顺序跨曲阅读，首尾不循环 |
| 连接两端 | 扫描电脑二维码配对，记住连接，更新目录及所选内容 |
| 离线携带 | 按曲谱或文件夹选择下载，iPad 系统后台队列、暂停与继续，保留已核验完整文件 |
| 同步资料 | 同步批注与曲单，保留冲突版本供查看 |
| 签名提示 | iPad 显示可解析的签名到期时间，电脑查看配对设备的历史报告 |
| Windows 入口 | 固定启动器、开始菜单快捷方式和任务栏身份，升级时切换版本目录 |

曲谱原文件保持只读。批注、曲单、索引和离线副本保存在应用数据目录，批注不会写回 PDF。

## 五步开始使用

1. **准备应用。** 开发者可按 [构建文档](docs/BUILDING.md) 生成 Windows 应用；iPad 已有构建见 [Releases](https://github.com/NonoKing123456/ipad-sheet-music-reader/releases)。带 `unsigned` 的 IPA 需要本地签名才能安装。
2. **电脑添加谱库。** 选择“添加谱库文件夹”，确认需要同步的文件已实际下载到电脑。
3. **连接两端。** 两台设备连接同一可信局域网，电脑打开“连接我的 iPad”，iPad 选择“扫描电脑二维码”，允许相机和本地网络访问。
4. **准备离线内容。** iPad 更新目录后，选择曲谱或文件夹“下载到 iPad”。顶部“更新目录”只更新目录元数据，任务在同步管理中查看、暂停或继续；后台调度受系统限制。目录可见不代表文件已下载。
5. **开始阅读。** 下载完成后断开电脑连接，检查演出曲单中的曲谱都能打开，再带去排练或演出。

完整操作见 [使用指南](docs/USER_GUIDE.md)。

## 阅读操作速查

| 操作 | 用途 |
| --- | --- |
| 点击页面左侧 / 右侧 | 在允许翻页的阅读状态下，上一页 / 下一页 |
| 点击页面中间 | 显示或收起阅读工具 |
| 未放大时水平滑动 | 翻页；批注或锁定等模式会影响手势 |
| 双指缩放、放大后拖动 | 放大并查看页面细节 |
| `Page Up` / `Page Down` | 上一页 / 下一页；按住不连续触发 |
| 谱库中 `Ctrl + F` | 展开搜索 |
| 曲单末页继续下一页 | 进入下一首；整张曲单末尾停留 |

发送 `Page Up` / `Page Down` 的键盘或脚踏可使用同一输入入口，具体硬件需实际验证。

## 从源码运行

仓库固定工具链为 Flutter `3.47.8`，Dart SDK 约束为 `^3.13.0`。先安装 Flutter，并将 `flutter` 和 `dart` 加入终端 PATH。

```sh
git clone https://github.com/NonoKing123456/ipad-sheet-music-reader.git
cd ipad-sheet-music-reader
flutter pub get --enforce-lockfile
flutter analyze lib test tool
```

**Windows：** 需要 Visual Studio 的 C++ 桌面开发组件及 Windows SDK。

```powershell
flutter run -d windows
flutter build windows --release --no-pub
```

发布时需保留完整 `build/windows/x64/runner/Release/`，不能只复制 EXE。固定启动入口的安装及插件链接问题见 [构建文档](docs/BUILDING.md)。

**iOS：** 需要 macOS 和匹配的 Xcode；现有云构建使用 `macos-26` / Xcode `26.6`。

```sh
flutter build ios --release --no-codesign --no-pub
```

这会生成未签名 `.app`，不会自动生成可安装 IPA。封装、原生检查和手动 Actions 流程见 [构建文档](docs/BUILDING.md)。

## 项目结构

```text
lib/                 Flutter 界面、阅读器、谱库与同步控制
packages/
  library_core/      只读文件索引、条目身份和内容版本
  reader_state/      批注、曲单、阅读位置及合并
  library_sync/      局域网传输、离线副本和设备状态
windows/             Windows C++ runner、资源与 CMake 工程
ios/                 iOS 工程及原生桥接
test/                使用合成文件和临时目录的应用测试
tool/                原生、存储和 Windows 插件链接工具
tools/windows/       固定启动器、快捷方式与本机版本发布工具
.github/             iOS 构建工作流和反馈模板
docs/                用户与开发文档
```

## 下载、更新与数据边界

- [Releases](https://github.com/NonoKing123456/ipad-sheet-music-reader/releases) 中的 `unsigned-ipad-<运行号>-<尝试号>` 是 iPad 构建预发布，不按最新正式版发布。Windows 目前以源码构建为入口。
- 成功的 iPad 构建提供 IPA、SHA-256 和 `build-info.txt`。**未签名 IPA 不能直接安装**，需自己的本地签名流程。
- iPad 更新时保持原 Bundle ID 和签名身份，先备份重要资料并覆盖安装。签名续期不等于升级应用；到期提示不代表自动续签成功。
- 同步使用 HTTP 和配对凭据认证，不提供 TLS 加密，只应在可信局域网使用，不映射到公网。
- 曲谱被外部替换后作为新内容版本处理，旧批注不会直接贴到新版上。
- 冲突保留双方版本；当前没有完整的选版解决流程。重要批注与原谱仍需备份。
- 离线文件占用设备空间，删除应用可能删除离线资料和批注。

项目尚处于持续完善阶段。当前不承诺 App Store / TestFlight 分发，也不把自动化或电脑预览等同于 iPad 实机验证。

本次 Windows 发布构建与静态检查通过，历史测试尚未全通过，具体结果及限制见 [验证记录](docs/VALIDATION.md)。

## 反馈与参与

遇到问题先查 [常见问题](docs/FAQ.md)，再通过 [Issues](https://github.com/NonoKing123456/ipad-sheet-music-reader/issues) 使用问题或功能建议模板。贡献代码与文档请看 [贡献指南](CONTRIBUTING.md)，安全问题见 [安全说明](SECURITY.md)。

本仓库尚未声明开源许可证；公开可见不等于已授予任意使用或再分发的许可。依赖项目按各自许可证使用。
