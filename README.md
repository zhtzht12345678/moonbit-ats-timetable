# moonbit-ats-timetable

MoonBit 列车自动监控（ATS）运行图调度与实时冲突检测器。

## 项目定位

这是一个面向轨道交通 OCC（运营控制中心）工具链的纯 MoonBit 库与 CLI。它把车站、区间、车次、停站、站台、进路资源和实时遥测统一成可校验的运行图模型，并输出可解释的冲突证据、调度建议、质量报表和 String Diagram 数据。

项目用于运行图校验、演练、回放和调度辅助，不直接控制信号设备。Hold、Skip、SpeedUp 和 SlowDown 建议都保留安全前置条件，最终执行由外部调度员或经过认证的控制系统复核。

## 核心能力

- 运行图建模：线路、里程、区间运行时间、车次、停站、站台与进路预约。
- 数据交换：派生 JSON 和文档化的轻量 XML 交换子集。
- 静态校验：标识、里程、区间约束、停站时序、平台和资源引用。
- 时空冲突：区间追踪间隔、站台占用、咽喉与进路资源重叠。
- 实时监控：遥测合并、延误增长、位置跳变、乱序、未知车次和陈旧数据。
- 调度与场景：滚动计划、Hold/Skip/SpeedUp/SlowDown 候选、封锁/限速/取消等事件评估。
- 运营指标：客流换乘、停站时间、资源压力、服务质量和延误分位数。
- 可视化输出：String Diagram JSON、NDJSON、冲突 CSV、SVG 辅助数据和 Markdown 报表。

## 快速开始

需要 MoonBit 0.10.3 或更新版本。本地验证使用 MoonBit 0.10.7。

~~~text
moon update
moon check --target all --deny-warn
moon test --target native --deny-warn
moon run --target native cmd/ats-demo -- --action conflicts
~~~

## CLI

演示 CLI：

~~~text
moon run --target native cmd/ats-demo -- --action check
moon run --target native cmd/ats-demo -- --action conflicts
moon run --target native cmd/ats-demo -- --action diagram
moon run --target native cmd/ats-demo -- --action xml
moon run --target native cmd/ats-demo -- --action metrics
moon run --target native cmd/ats-demo -- --action simulate --json
moon run --target native cmd/ats-demo -- --action health
moon run --target native cmd/ats-demo -- --action operations
moon run --target native cmd/ats-demo -- --action quality
moon run --target native cmd/ats-demo -- --action scenario
moon run --target native cmd/ats-demo -- --action plan
moon run --target native cmd/ats-demo -- --action recovery
~~~

基准 CLI：

~~~text
moon run --target native cmd/ats-bench --
moon run --target native cmd/ats-bench -- --case medium --json
~~~

## 架构

`types.mbt` 定义公开模型；`validation.mbt`、`serialization.mbt`、`conflicts.mbt`、`interval_index.mbt`、`resources.mbt`、`topology.mbt`、`monitor.mbt`、`operations.mbt`、`service_quality.mbt`、`disruptions.mbt`、`strategy.mbt`、`dispatch_planner.mbt`、`recovery.mbt`、`analytics.mbt`、`planning.mbt` 和 `renderer.mbt` 分别负责校验、交换、冲突、查询、资源、路径、实时、运营、质量、场景、策略、计划恢复、指标和渲染。`benchmark.mbt` 提供可复现工作负载，`demo.mbt` 提供合成演示。

核心时间和距离计算使用整数，避免浮点数造成边界漂移。区间检测采用半开时间窗，便于在适配层按时间窗或资源分片。

## 基准

完整命令、工具链、主机信息和现场输出见 [docs/benchmark.md](docs/benchmark.md)。当前本地原生运行的三档工作负载为 8×24、16×72 和 24×144（站点×车次），每档输出冲突观测、区间查询、资源重叠、客流观测和确定性校验和。

## 测试

测试覆盖模型非法输入、时间边界、半开区间、反向查询窗口、拓扑不可达、资源窗口、场景影响、陈旧遥测、容量钳制、序列化失败和基准可复现性。

## CI

`.github/workflows/check.yml` 覆盖 Linux、macOS 和 Windows，执行全目标 `moon check --deny-warn`、`moon test --deny-warn`、原生构建、格式检查、接口信息生成和工作区差异检查。

当前稳定工具链的 `moon fmt` 与 `moon info` 不接受 `--deny-warn`；严格告警由 check/test 门禁完成，再执行官方支持的 `fmt --check` 与 `info`。

## 输入边界与来源

XML 接口是本项目定义的轻量交换子集，不承诺兼容任何厂商私有 ATS schema。演示线路、车次、遥测和故障数据均为合成数据，不对应真实线路或运营机构。运行时依赖仅使用 MoonBit 官方核心 JSON 包。

## 许可证

Apache License 2.0，详见 [LICENSE](LICENSE)。
