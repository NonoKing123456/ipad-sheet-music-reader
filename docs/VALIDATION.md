# 验证情况

验证日期：2026-11-02。构建、安装和真机验证分别记录；下方保留 `0.8.10+26` 公开副本的历史测试结果，不把后续定向验证视为全量通过。

## 当前更新：Windows +27 已交付，iPad +28 源码候选

| 范围 | 已有证据与边界 |
| --- | --- |
| `0.8.10+27` 文字批注 | 定向分析的 10 个文件及 `reader_state/lib` 无问题；12 项定向测试通过，覆盖 Windows / iOS 目标变体的原位输入、多图层编辑互斥、旧控件、字体及旋转保存 / 撤销 / 合并和兼容性 |
| 文字布局与软键盘避让 | 已审阅合成界面截图；测试模拟键盘遮挡，验证底部旋转输入框移到可见范围、追加文字及完成 / 取消后恢复视图。该证据不等于原生 iPad 键盘或系统字体实测 |
| Windows `0.8.10+27` | Release 已构建并交付，固定启动器保持不变，部署指针已切到 `+27` |
| iPad 顶部操作 | 6 项界面测试通过，已审阅空闲 / 下载状态预览；截图依赖移出公开测试后，公开文件分析通过，未把该拆分声称为另一次界面重测 |
| 后台下载与传输进度 | 8 项后台契约与恢复测试、13 项核心包传输进度测试通过；后台改动与公开测试定向分析无问题。模拟原生队列与 Dart 恢复不等于系统后台调度、原生持久化或息屏传输实测 |
| iPad `0.8.10+28` | 已合并文字、顶部操作与系统后台下载实现，源码候选已冻结；构建状态以对应 Release 及 `build-info.txt` 为准，仍待安装与真机验证 |

本机 Windows 无 Xcode，新 Swift 实现尚待 Mac 编译；当前没有 `+28` 的签名安装、真实后台 / 息屏传输、强制划掉后恢复或当前无 Range 服务中断续传通过结论。Windows 已交付版本与 iPad 候选版本分开，不以模拟 iOS 界面或 Windows 构建替代真机结果。

文字与顶部预览的本机专用截图测试 `test/annotation_text_inline_0810_test.dart`、`test/offline_header_preview_private_test.dart` 不纳入公开副本；12 项文字定向验证含私有测试，不能解读为公开仓库中可复跑的 12 项测试。公开的字体状态、文字控件和顶部操作测试不依赖这些截图文件。

## 0.8.10+26 公开副本基线：已通过

以下记录针对当时的 Windows 工程、测试和文档补充，不修改既有阅读器或同步实现来消除历史测试失败。

| 检查 | 结果 |
| --- | --- |
| 按根锁文件解析依赖 | 完成；本机插件链接使用已公开 junction 辅助工具 |
| `flutter analyze --no-pub lib test tool` | 无问题 |
| 三个核心包 `dart analyze` | 均无问题 |
| `flutter build windows --release --no-pub` | 成功生成完整 Windows Release 目录 |
| `library_core` 的 `dart test` | 21 通过、1 因当前主机无法创建符号链接而跳过 |
| 公开源码核对 | 产品源码与本机已交付版本对应，未上传私人曲谱或状态 |
| 文档与反馈模板 | 核对相对链接及 YAML 格式 |

构建在 Windows x64、项目固定 Flutter 工具链下进行。构建成功不代表所有用户流程或外设已完成实测。

## 0.8.10+26 公开副本基线：尚未全通过的历史测试

公开测试包含早期阶段的回归断言，并非已经全部与当前产品同步更新。原断言保留，未通过隐藏或跳过失败来制造全绿结果。

| 测试范围 | 本次观察 |
| --- | --- |
| `reader_state` | 47 通过、1 失败；旧迁移测试仍期待 schema 2，当前保存格式为 3 |
| `library_sync` | 37 通过、1 跳过、4 失败；涉及冲突预期和旧协议请求收到 HTTP 426 |
| 根应用 `flutter test` | 运行摘要为 99 通过、1 跳过、40 失败，另有 4 项报告未完成；包含旧 schema、旧界面结构、快捷输入及交互断言不匹配，需逐项确认过期测试与实际问题 |

典型待排查位置：

- `test/annotation_path_test.dart` 的持久格式断言。
- `test/app_smoke_test.dart` 的首页控件查找。
- `test/library_reader_focus_test.dart`、`test/library_reader_preview_test.dart` 的输入与界面交互。
- `packages/reader_state/test/merge_test.dart` 的旧 schema 迁移预期。
- `packages/library_sync/test/sync_test.dart` 的合并冲突与旧请求协议预期。

这些观察不能一概解释为“只是旧测试”，也不能据此承诺现有产品没有对应问题。后续应以当前交互和兼容约定逐项复现，再决定修正测试或实现。

## 0.8.10+26 公开副本基线：未覆盖

本次没有重新运行 iOS 云构建、签名安装、真实 iPad、物理局域网、笔或脚踏、自动续签和任务栏手动固定。iOS 工作流与既有构建记录保留，不以本次 Windows 构建替代它们的验证。

五个依赖特定本机字体、SDK 路径或专用截图验收进程的历史测试未公开：`desktop_reader_085_test.dart`、`directory_history_087_test.dart`、`reader_experience_test.dart`、`reader_fixes_088_test.dart`、`reader_motion_089_test.dart`。其他测试使用的桌面合成辅助函数单独保存在 `test/desktop_reader_fixture.dart`。
