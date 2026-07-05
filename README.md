# MacOS-TSKMGR

最新版本链接：https://github.com/JOHN-decm/MacOS-TSKMGR/releases/tag/1.1.1

Latest Release：https://github.com/JOHN-decm/MacOS-TSKMGR/releases/tag/1.1.1

## 免责声明 / Disclaimer

本项目是一个开源仿制项目，界面灵感来源于 Windows 任务管理器，仅供在 macOS 上用于学习和个人使用。它与微软公司没有任何关联，也未获得微软公司的认可、授权或背书。
Windows是微软公司的注册商标。

This project is an open-source clone inspired by the Windows Task Manager UI, created for educational and personal use on macOS. It is not affiliated with, endorsed by, or associated with Microsoft Corporation in any way.
Windows is a registered trademark of Microsoft Corporation.

## 介绍 / Intro

一个面向 macOS 26 的原生任务管理器项目，界面和交互风格参考 Windows 10 任务管理器，同时尽量保留 macOS 上更底层的实时监控能力。基于 SwiftUI 与 AppKit 的桌面应用，支持 Intel 与 Apple Silicon，并分别提供对应架构的独立 `.app` 打包产物。

A native task manager for macOS 26, visually and behaviorally inspired by Windows 10 Task Manager while keeping access to lower-level real-time macOS metrics. It is a SwiftUI + AppKit desktop application with separate standalone `.app` packages for Intel and Apple Silicon.

<img src="Assets/Screenshot 2026-06-29 at 11.04.29.png" alt="Screenshot 2026-06-29 at 11.04.29" style="zoom:67%;" />

## 项目定位 / Positioning

这个项目的目标不是完全复刻系统“活动监视器”，而是做一套更接近 Windows 任务管理器习惯的任务、性能与设备状态面板。你可以把它理解成一套“macOS 上的 Task Manager 风格前端”，配合本机进程、磁盘、网络、GPU、NPU 与散热数据，把常用的查看、结束、切换与诊断动作集中到一个窗口里。

The goal is not to clone Activity Monitor one-to-one, but to build a macOS utility with a workflow closer to Windows Task Manager. Think of it as a Task Manager-style front end for macOS that brings process control, performance graphs, device state, and quick diagnostics into one window.

## 系统支持 / System Support

最低支持版本为 macOS 26.0。项目同时考虑 Intel 与 Apple Silicon，两种架构分别构建与分别打包；语言默认按系统首选语言决定，系统为简体中文时使用中文，其他情况下默认显示英文；温度单位默认使用摄氏度，华氏度保留为界面内可手动切换的可选项。

The minimum supported version is macOS 26.0. The project supports both Intel and Apple Silicon, with separate builds and separate packaged apps for each architecture. The UI defaults to Simplified Chinese only when the system preferred language is `zh-Hans`; otherwise it defaults to English. Temperature is shown in Celsius by default, with Fahrenheit available as a manual in-app option.

<img src="Assets/Screenshot 2026-06-29 at 11.08.23.png" alt="Screenshot 2026-06-29 at 11.08.23" style="zoom:67%;" />

## 功能概览 / Feature Overview

应用当前覆盖进程、性能、应用历史记录、启动、用户、详细信息、服务等页面，并提供紧凑模式、结束任务、重新启动 Finder 类进程、运行新任务、切换刷新频率、置顶显示、网络详情面板与关于面板等常用交互。性能页除了 CPU、内存、磁盘、网络之外，还包含 GPU、NPU 以及散热页面，适合做实时观察和快速定位。

The current app includes pages for Processes, Performance, App History, Startup, Users, Details, and Services, along with compact mode, end-task actions, Finder-style restart actions, Run New Task, refresh-speed switching, always-on-top, a network detail panel, and an About panel. Beyond CPU, memory, disk, and network, the Performance view also includes GPU, NPU, and Cooling pages for real-time inspection and quick troubleshooting.

## 界面风格 / Visual Style

窗口主体采用原生 macOS 模糊材质与分层叠色，整体布局尽量贴近 Windows 任务管理器的阅读顺序：左侧为性能与设备导航，右侧为详细图表与指标，底部保留简略信息/详细信息切换与主要操作按钮。深色与浅色模式都做了独立调校，重点不是“像网页”，而是像一套真正的桌面工具。

The window uses native macOS blur materials and layered overlays while preserving a Windows Task Manager-like reading order: performance and device navigation on the left, detailed charts and metrics on the right, and a bottom control bar for compact/full switching and primary actions. Both dark and light appearances are tuned independently to feel like a desktop utility rather than a browser page.

<img src="Assets/Screenshot 2026-06-29 at 11.10.55.png" alt="Screenshot 2026-06-29 at 11.10.55" style="zoom:67%;" />

<img src="Assets/Screenshot 2026-06-29 at 11.11.13.png" alt="Screenshot 2026-06-29 at 11.11.13" style="zoom:67%;" />

## 性能与硬件页面 / Performance and Hardware Pages

CPU 页面支持整体利用率与逻辑处理器视图，Apple Silicon 机型还会尝试识别不同核心层级并展示对应基准频率与温度标签；GPU 页面展示利用率、3D/Tiler 数据与共享 GPU 内存；NPU 页面展示 Active、Power、Data Movement 与 Memory 四类图形；散热页面则整合风扇转速、CPU/GPU/磁盘/网卡/SoC/主板等温度来源，并对无风扇机型做单独适配。

The CPU page supports both overall utilization and logical-processor views, and on Apple Silicon it also attempts to identify core tiers and display matching base-frequency and temperature labels. The GPU page shows utilization, 3D/Tiler activity, and shared GPU memory. The NPU page focuses on Active, Power, Data Movement, and Memory graphs. The Cooling page combines fan RPM and temperature sources for CPU, GPU, disk, Wi-Fi, SoC, logic board, and more, including a dedicated fallback behavior for fanless machines.

## NPU / ANE 实现说明 / NPU / ANE Notes

NPU 部分已经从早期的启发式估算，逐步迁移到基于私有 `IOReport` 的实测链路。当前主要读取 `Energy Model`、`ANS2 Power` 与 `AMC Stats Perf Counters`，用于生成功耗、活跃度以及数据搬运曲线；同时保留神经共享内存占用的实时展示。它的目标不是伪装成“官方公开 API”，而是在可接受的工程复杂度内尽量靠近真实硬件状态。

The NPU implementation has moved away from the early heuristic model and toward a private `IOReport`-based measurement pipeline. It currently reads from `Energy Model`, `ANS2 Power`, and `AMC Stats Perf Counters` to drive Power, Activity, and Data Movement graphs, while also showing neural shared-memory usage. The intent is not to pretend this is a public Apple API, but to get as close as possible to real hardware behavior within a practical engineering tradeoff.

详细交接文档见 [NPU.md](NPU.md)。

For detailed handoff notes, see [NPU.md](NPU.md).

<img src="Assets/截屏2026-06-28 02.24.08.png" alt="截屏2026-06-28 02.24.08" style="zoom:67%;" />

## 散热实现说明 / Cooling Notes

散热页面的风扇主要来自 `AppleSMC`，温度数据则综合 `SMC`、HID 温度节点与板级传感器映射。当前覆盖 CPU、GPU、磁盘、网卡、SoC、逻辑板、电源表面、外壳等项目，并针对有风扇与无风扇机型分别处理主图逻辑。它更偏向实用型硬件观测页面，而不是只做单一风扇读数展示。

The Cooling page reads fan data mainly from `AppleSMC`, while temperature values are combined from `SMC`, HID temperature nodes, and board-level sensor mappings. It currently covers CPU, GPU, disk, Wi-Fi, SoC, logic board, power surface, enclosure, and more, with separate graph behavior for fan-equipped and fanless machines. The goal is a practical hardware-observation page rather than a fan-RPM-only display.

详细交接文档见 [THERMAL.md](THERMAL.md)。

For detailed handoff notes, see [THERMAL.md](THERMAL.md).

<img src="Assets/Screenshot 2026-06-29 at 11.15.36.png" alt="Screenshot 2026-06-29 at 11.15.36" style="zoom:67%;" />

## 技术路线 / Technical Approach

工程主体是一个 Xcode 原生 macOS 项目，核心界面使用 SwiftUI，窗口和部分系统交互由 AppKit 补充。系统监控数据主要来自 `sysctl`、`host_statistics`、`proc_pidinfo`、`proc_pid_rusage`、`IOKit`、`CoreWLAN`、`CGWindowList`、`launchctl` 以及少量私有或半私有接口。项目没有引入第三方跨平台 UI 框架，重点在于把系统数据采集、桌面窗口行为和任务管理器式布局统一到同一个原生工程里。

This is a native macOS Xcode project. The main UI is built with SwiftUI, with AppKit used for window configuration and selected system interactions. Monitoring data comes primarily from `sysctl`, `host_statistics`, `proc_pidinfo`, `proc_pid_rusage`, `IOKit`, `CoreWLAN`, `CGWindowList`, `launchctl`, and a small number of private or semi-private interfaces. There is no third-party cross-platform UI stack; the focus is on keeping system data collection, desktop window behavior, and Task Manager-style layout inside one native codebase.

## 构建与打包 / Build and Packaging

日常开发以 Xcode 工程为主，发布时提供 `arm64` 与 `x86_64` 两种独立 `.app`。

Development is centered around the Xcode project, and releases are provided as separate `.app` bundles for `arm64` and `x86_64`.

## 签名与分发现实 / Signing and Distribution

由于目前没有 Apple Developer Program 签名资格，这个应用暂时无法提供正式签名版本，也不会上架 Mac App Store。当前分发与测试方式仍然是手动放行 Gatekeeper。

Because there is no active Apple Developer Program signing setup for this project, it does not currently ship with a formal production signature and is not distributed through the Mac App Store. For now, distribution and testing still rely on manually allowing the app through Gatekeeper.

## 风险与说明 / Notes and Limitations

部分硬件监控能力依赖私有或非公开文档的系统接口，因此未来 macOS 更新、芯片代际变化或不同机型之间，某些指标可能需要重新校准或重新映射。尤其是 Apple Silicon 上的核心层级识别、NPU 图表含义与板级温度映射，都属于“持续验证、逐步修正”的工程范围，而不是 Apple 官方保证长期稳定的公开契约。

Some hardware-monitoring paths depend on private or undocumented system interfaces, so certain metrics may require recalibration or remapping across future macOS releases, new chip generations, or different machine families. Apple Silicon core-tier detection, NPU graph semantics, and board-level temperature mappings should all be treated as evolving engineering work rather than long-term public contracts guaranteed by Apple.

## 项目状态 / Project Status

这是一个已经有实际发布与维护节奏的原生工具项目，但它仍然更接近“持续打磨中的实验型桌面软件”，而不是承诺长期稳定 API 的平台型产品。欢迎 issue、bug report 和机器样本反馈，特别是针对新芯片、新系统版本以及图表/传感器异常的反馈。

This project is already a real, maintained native utility, but it is still closer to an actively refined experimental desktop tool than to a platform product with long-term stable APIs. Issues, bug reports, and machine-specific feedback are especially useful, particularly for new chips, new macOS releases, and graph or sensor anomalies.

## 致谢 / Credits

部分实现过程使用了 AI 辅助生成与整理代码；如果你认为某段代码、文案或实现路径涉及不当引用或需要署名修正，欢迎直接提交 issue 说明。

Some parts of the implementation were assisted by vibe coding. If you believe any code, wording, or implementation path needs attribution correction or raises a reuse concern, please open an issue directly.
