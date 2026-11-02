# 安装与构建

[返回首页](../README.md) · [架构说明](ARCHITECTURE.md)

## 环境与版本

| 项目 | 当前配置 |
| --- | --- |
| Flutter | `3.47.8` |
| Flutter revision | `737ba8f885dc774b53b442759999a312c9461e4e` |
| Dart SDK 约束 | `^3.13.0` |
| Windows | Windows x64、Visual Studio C++ 桌面开发组件、Windows SDK |
| iOS 本地构建 | macOS、Xcode `26.6` |
| iOS 云构建 | `macos-26-intel` x86_64 主机、同 Xcode `26.6`，设备目标仍为 iOS / arm64 |
| 依赖版本 | 根 `pubspec.lock`，按锁文件解析 |

这些是当前项目配置，不是对最新工具版本的推荐。升级 SDK、Xcode 或锁文件应单独审查。以下命令在仓库根目录运行，`flutter`、`dart` 应在 PATH 中。

```sh
flutter --version
flutter doctor -v
flutter pub get --enforce-lockfile
flutter analyze lib test tool
```

## Windows 开发与发布

```powershell
flutter run -d windows
flutter build windows --release --no-pub
```

发布输出为 `build/windows/x64/runner/Release/`。必须分发整个目录，包含 EXE、DLL、`data/` 和原生资产，不能只发 `score_reader.exe`。

若依赖解析成功，但创建插件符号链接失败，可以使用项目的 junction 辅助工具，再执行构建：

```powershell
.\tool\prepare_windows_links.ps1
flutter build windows --release --no-pub
```

辅助工具要求 `.flutter-plugins-dependencies` 已由依赖解析生成，只操作项目内插件链接，不调整系统设置。如果依赖解析本身失败，先修复依赖错误。

开发时可为测试实例指定独立状态目录；将示例路径替换为自己的绝对路径：

```powershell
.\build\windows\x64\runner\Release\score_reader.exe --data-dir 'C:\score-reader-test\instance-a'
```

不同实例不可共享状态目录。固定启动器和开始菜单入口的可选部署见 [Windows 发布工具](../tools/windows/README.md)。普通构建、静态分析和测试不会自动安装启动器或改动已有部署。

## 测试

```sh
flutter test --no-pub --concurrency=1
```

三个纯 Dart 包分别安装依赖、分析和测试，例如：

```sh
cd packages/library_core
dart pub get
dart analyze
dart test
```

对 `packages/reader_state` 和 `packages/library_sync` 执行同样步骤。这些独立包有各自的开发依赖，根应用的 `pub get` 不会替它们安装测试依赖。

公开测试使用合成文件和临时目录。五个依赖特定本机字体、SDK 位置或专用验收进程的历史截图测试未纳入公开副本；这里的 `flutter test` 指仓库内已公开测试，不代表全部历史验收。

部分已公开历史测试尚未与当前界面、数据格式和协议对齐，本次没有全量通过。已知结果和待排查位置见 [验证记录](VALIDATION.md)。

Windows / Dart 3.13 曾出现测试宿主原生采样崩溃。如果日志表现为进程崩溃而非断言失败，应保留崩溃日志区分原因；不要用关闭断言或修改产品逻辑掩盖。实际测试结果按运行环境记录。

## iOS 本地构建

macOS 上安装匹配工具链后：

```sh
xcodebuild -version
flutter precache --ios
flutter pub get --enforce-lockfile
dart --packages=.dart_tool/package_config.json tool/storage_root_smoke.dart --require-links
flutter build ios --release --no-codesign --no-pub
```

输出为 `build/ios/iphoneos/Runner.app`。Windows 本机无法执行此 iOS 构建。`--no-codesign` 不执行账号登录或签装。

需要供后续本地签名使用的 IPA 时，可在 macOS 上将成功生成的应用封装至新的临时目录：

```sh
package_dir="$(mktemp -d)"
mkdir -p "$package_dir/Payload"
ditto build/ios/iphoneos/Runner.app "$package_dir/Payload/Runner.app"
ditto -c -k --keepParent "$package_dir/Payload" "$package_dir/score-reader-unsigned.ipa"
shasum -a 256 "$package_dir/score-reader-unsigned.ipa"
echo "$package_dir"
```

这仅封装容器，不自动验证嵌套二进制或完成签名。工作流同等级的校验请参照 [iOS 工作流](../.github/workflows/ios-unsigned.yml)。

## 原生检查

macOS 上可运行公开的合成图像和签名解析检查：

```sh
smoke_dir="$(mktemp -d)"
xcrun swiftc -swift-version 5 -parse-as-library \
  ios/Runner/AppDelegate.swift tool/raster_decode_smoke.swift \
  -o "$smoke_dir/raster-decode-smoke"
"$smoke_dir/raster-decode-smoke" --make-fixture "$smoke_dir/raster-fixture.PNG"
"$smoke_dir/raster-decode-smoke" --decode "$smoke_dir/raster-fixture.PNG"
xcrun swiftc -swift-version 5 -parse-as-library \
  ios/Runner/ProvisioningExpiry.swift tool/signing_expiry_smoke.swift \
  -o "$smoke_dir/signing-expiry-smoke"
"$smoke_dir/signing-expiry-smoke"
```

这些检查不使用真实描述文件或私人曲谱，也不能替代物理 iPad、真实 Wi-Fi、笔输入或续签验证。

## 手动 GitHub Actions

当前工作流限定于本公开仓库。仓库所有者可打开 **Actions → iOS unsigned device build → Run workflow**，选择分支，确认只含可公开源码，勾选 `public_source_confirmed` 后运行。

- 自动触发条件是 `main` 的工作流文件自身发生变更；普通文档和应用源码提交不自动触发 iOS 云构建。
- 单次上限 25 分钟，使用既有固定工具链，不通过更换付费 runner 解决失败。
- 检查存储边界、图像解码、签名日期解析和嵌套 Mach-O 的 iOS / arm64。
- 产物发布为预发布，不设为最新正式版，不使用 Actions artifact 保存安装包。
- `REVIEWED_SOURCE_SHA256` 记录既有人工审核归档，不能当作当前整个仓库的哈希。实际来源以 `build-info.txt` 中的 Git 提交及对应源码为准。

## 下载、校验和安装

[Releases](https://github.com/NonoKing123456/ipad-sheet-music-reader/releases) 的每次成功 iPad 构建包含：

| 文件 | 用途 |
| --- | --- |
| `score-reader-unsigned.ipa` | 未签名设备应用容器 |
| `score-reader-unsigned.ipa.sha256` | 下载完整性校验 |
| `build-info.txt` | 源码提交、工具链和检查信息 |

下载同一条预发布的三份文件，在 macOS 校验：

```sh
shasum -a 256 -c score-reader-unsigned.ipa.sha256
```

PowerShell 中计算并与校验文件对照：

```powershell
Get-FileHash -Algorithm SHA256 .\score-reader-unsigned.ipa
Get-Content .\score-reader-unsigned.ipa.sha256
```

校验通过说明下载字节一致，不代表已签名、安装或真机验收。未签名 IPA 仍需自己的本地签名流程，例如已配置好的 Sideloadly；账号、证书和描述文件只在本地签名环境使用。更新保持原 Bundle ID 和身份，先备份再覆盖安装。
