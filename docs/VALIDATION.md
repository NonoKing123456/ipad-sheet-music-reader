# 本次公开副本的验证情况

验证日期：2026-11-02。对象为公开源码 `0.8.10+26` 及本次 Windows 工程、测试和文档补充，不修改既有阅读器或同步实现来消除历史测试失败。

## 已通过

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

## 尚未全通过的历史测试

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

## 未覆盖

本次没有重新运行 iOS 云构建、签名安装、真实 iPad、物理局域网、笔或脚踏、自动续签和任务栏手动固定。iOS 工作流与既有构建记录保留，不以本次 Windows 构建替代它们的验证。

五个依赖特定本机字体、SDK 路径或专用截图验收进程的历史测试未公开：`desktop_reader_085_test.dart`、`directory_history_087_test.dart`、`reader_experience_test.dart`、`reader_fixes_088_test.dart`、`reader_motion_089_test.dart`。其他测试使用的桌面合成辅助函数单独保存在 `test/desktop_reader_fixture.dart`。
