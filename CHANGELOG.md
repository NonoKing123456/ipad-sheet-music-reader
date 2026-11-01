# 版本记录

本文件记录公开源码的重要变化，不等同于安装包发布清单。较早记录根据 Git 历史整理，未补造发布日期；具体 iPad 包以预发布中的 `build-info.txt` 为准。

## 0.8.10+28（iPad 源码候选）

- 合入 `0.8.10+27` 的原位文字批注、字体选择、移动 / 缩放旋转 / 换行宽度控制点和键盘避让。
- 接入 iPad 系统后台下载队列，支持管理任务、暂停和继续，保留已完成且通过校验的文件。切换应用、息屏后的调度受系统限制；强制划掉应用会取消系统传输，需重新打开后继续。当前电脑服务不支持 Range，缺少可用续传数据时当前未完成文件可能重下。
- 顶部“更新目录”只刷新目录元数据，不重新启动下载；忙碌时统一显示一个进度指示，通过状态入口进入同步管理，精简重复三点菜单和曲单入口。
- 候选实现与本机定向检查已完成；原生 Swift 仍需 Mac 构建验证，包的构建状态以对应 Release 及 `build-info.txt` 为准。尚无此版本安装、真机后台、息屏或键盘验证结论。

## 0.8.10+27（Windows 已交付）

- 文字直接在谱面原位输入，顶部提供字体选择、取消与完成，移除大弹窗和独立字号输入。
- 通过三个控制点移动文字、缩放并旋转、调整换行宽度；收紧文字框留白，底部输入随软键盘临时避让。
- 字体及旋转状态随批注保存，并纳入撤销、重做和合并处理。
- Windows Release 已构建并发布到固定启动入口；iPad 将与后台下载改进合并至 `0.8.10+28`，没有单独发布 `+27` iPad 包。

## 0.8.10+26

- 公开 Windows C++ runner、CMake 工程及固定启动器相关源码。
- Windows 固定入口使用统一任务栏身份；发布工具校验完整版本目录后切换部署指针。
- 纳入 Windows 列表“打开文件所在目录”操作。
- 补充可移植应用测试、三个核心包测试及配置；复用桌面测试辅助代码，排除五个依赖特定本机环境的历史截图测试。
- 重写中文项目首页，补齐使用、构建、架构、排错、安全和贡献说明，以及 Issue / PR 模板。
- 此次仓库完善不自动运行 iOS 云构建，也不把新源码标记为已签装的 iPad 发布。

## 0.8.10+24

- Windows 本地谱库采用普通文件、文件夹图标。
- 保留 iPad 离线状态角标，与电脑本地文件语义分开。

## 0.8.10+23

- 精简轮廓图标，使用清晰的角落下载状态。
- 保留阅读器跨曲预载与紧凑谱库布局。

## 更早的公开改进

| 主题 | 公开提交 |
| --- | --- |
| 图标与曲单切换预载 | [`389b31e`](https://github.com/NonoKing123456/ipad-sheet-music-reader/commit/389b31e) |
| 签名状态、翻页与离线库控制 | [`538c859`](https://github.com/NonoKing123456/ipad-sheet-music-reader/commit/538c859) |
| 阅读工具、目录元数据和桌面导航 | [`d7b049f`](https://github.com/NonoKing123456/ipad-sheet-music-reader/commit/d7b049f) |
| iPad 签名到期提示及电脑镜像 | [`ba24567`](https://github.com/NonoKing123456/ipad-sheet-music-reader/commit/ba24567) |
| 大谱库响应与桌面阅读模式 | [`d495e3d`](https://github.com/NonoKing123456/ipad-sheet-music-reader/commit/d495e3d) |
| 大谱库恢复及文字批注 | [`2fd9b01`](https://github.com/NonoKing123456/ipad-sheet-music-reader/commit/2fd9b01) |
| 批注图层及曲单准备 | [`1824f85`](https://github.com/NonoKing123456/ipad-sheet-music-reader/commit/1824f85) |
| 多来源谱库与选择性离线下载 | [`92d7c84`](https://github.com/NonoKing123456/ipad-sheet-music-reader/commit/92d7c84) |

后续版本应区分源码变化、构建结果、安装状态与实际硬件验收，避免用一次状态代替其他状态。
