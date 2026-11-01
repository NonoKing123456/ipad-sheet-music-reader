# Windows 固定启动入口与本机发布

[返回首页](../../README.md) · [构建文档](../../docs/BUILDING.md)

固定 GUI 启动器安装于 `%LOCALAPPDATA%\Programs\SheetMusicReader\曲谱阅读器.exe`。旁边的 `deployment.json` 指向一个完整版本目录。启动器、阅读器窗口与开始菜单快捷方式使用同一 AppUserModelID：`SheetMusicReader.Desktop`。

## 准备并发布

在仓库根目录构建，复制完整输出至符合命名规则的版本目录，再运行发布脚本：

```powershell
flutter build windows --release --no-pub
Copy-Item -LiteralPath '.\build\windows\x64\runner\Release' -Destination '.\artifacts\reader-update-0.8.10+26-win-x64' -Recurse
.\tools\windows\Publish-Reader.ps1 -ReleaseDirectory '.\artifacts\reader-update-0.8.10+26-win-x64'
```

复制目标必须是尚不存在的新目录，避免混入旧文件。版本号应与实际 `pubspec.yaml` 一致；这里以 `0.8.10+26` 为例。

脚本校验目前固定的 18 个非空发布文件、拒绝目录中的链接，并核对 EXE ProductVersion 与版本目录名称。通过临时指针验证后，才原子切换 `deployment.json`。

首次安装会使用本机 .NET Framework C# 编译器和 Windows SDK 资源编译器构建启动器，嵌入现有图标与名称资源，并创建当前用户开始菜单快捷方式。脚本不下载工具、不要求管理员权限。

普通后续发布只切换部署指针；需要显式升级启动器或修复快捷方式时才加 `-InstallLauncher`。发布不会启动或终止阅读器、修改阅读数据或自动固定任务栏。保存后自行关闭旧窗口，再从固定入口启动。

## 验证与回退

只读检查当前部署，不启动阅读器：

```powershell
$readerLauncher = Join-Path $env:LOCALAPPDATA 'Programs\SheetMusicReader\曲谱阅读器.exe'
Start-Process -FilePath $readerLauncher -ArgumentList '--verify' -Wait -WindowStyle Hidden -PassThru
```

GUI 程序不会总在父终端显示 JSON，退出码可判断成功与失败。需要保存结果时，传入绝对 `--output` 路径；输出目录应事先存在。

`--verify` 检查全部发布成员，`--resolve-only` 仅解析并检查目标 EXE。检查模式可通过 `--pointer` 指定候选指针。普通启动参数按 Windows Unicode 规则传给阅读器，不经过 shell。

回退时对保留的旧版本目录再次运行同一发布命令。当前引用的版本目录必须保留；切换指针不搬移、清理或删除版本文件。

## 文件职责

| 文件 | 用途 |
| --- | --- |
| `StableLauncher.cs` | 固定入口、参数转发、部署解析及验证 |
| `ShortcutIdentity.cs` | 创建和核对原生快捷方式身份 |
| `launcher.rc` | 启动器图标与显示资源 |
| `Publish-Reader.ps1` | 校验版本、安装入口及切换部署指针 |

此流程是可选的本机安装工具，运行普通应用测试不会安装它。涉及开始菜单或任务栏的真实交互仍需本机验证。
