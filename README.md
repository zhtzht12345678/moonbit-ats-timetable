# moonbit-ats-timetable

MoonBit 列车自动监控（ATS）运行图调度与实时冲突检测器。

这是一个面向轨道交通 OCC（运营控制中心）工具链的纯 MoonBit 运行图分析库：它统一建模车站、区间、车次、停站、进路资源和实时遥测，并输出冲突告警、调度建议和 Web String Diagram 数据。

项目定位是调度辅助与仿真前置校验器，不是直接控制信号设备的安全关键控制器。Hold、Skip、SpeedUp 和 SlowDown 建议都带有前置条件，必须由调度员或经过认证的控制系统复核后执行。

## 功能

- 运行图建模、结构化校验和 JSON/XML 交换；
- 里程—时间斜线区间的 Headway Conflict 检测；
- 同站同站台占用与咽喉/进路资源冲突检测；
- 遥测合并、延误增长、位置跳变、未知车次和陈旧数据告警；
- 带安全边界的 Hold、Skip、SpeedUp、SlowDown 调度建议；
- String Diagram JSON、NDJSON、冲突 CSV 和 SVG 展示辅助；
- 确定性仿真、负载分析、健康指标和计划复核报告。

当前 Mooncakes 关键词检索覆盖 train、railway、timetable、ATS、headway、conflict detection 和 dispatch，命中的主要是通用 scheduler、cron、事件模拟和拓扑排序类包，没有发现与本项目功能高度重合的成熟 ATS 运行图项目。

## 快速开始

需要 MoonBit 0.10.3 或更新版本，本仓库开发和验证使用 0.10.7。

~~~text
moon check --target all --deny-warn
moon test --target native --deny-warn
moon run --target native cmd/ats-demo -- --action conflicts
moon run --target native cmd/ats-demo -- --action diagram
moon run --target native cmd/ats-demo -- --action simulate --json
~~~

## 目录

公开模型位于 types.mbt；validation、serialization、conflicts、monitor、strategy、renderer、analytics、planning 和 demo 分别承担校验、交换、冲突、实时、策略、渲染、分析、计划复核和示例职责。cmd/ats-demo 是可运行 CLI。

核心算法使用整数分钟和整数米，避免浮点边界误差。当前冲突检测适合离线校验、演练和中等规模实时快照；超大线网可在适配层按时间窗或资源分片。

## 测试与 CI

.github/workflows/check.yml 参考 MoonBit 社区 workflow template，覆盖 Linux、macOS、Windows，并执行 moon check --target all --deny-warn、moon test --target all --deny-warn、moon fmt --check 和 moon info。

当前 MoonBit 0.10.7 的 fmt/info 子命令不接受 deny-warn；严格告警由 check/test 门禁完成，再执行官方模板使用的 fmt/info 检查。

## 许可证与来源

本项目采用 Apache-2.0，详见 LICENSE。核心源码为本仓库原创 MoonBit 实现，没有复制 ATS 商业软件、私有代码、闭源代码或来源不明的生成内容。演示线路、车次、遥测和故障数据均为合成数据，不对应任何真实线路或运营机构。

项目不包含自动驾驶、信号机控制和联锁逻辑；这些内容应由符合铁路安全标准的专用系统承担。

