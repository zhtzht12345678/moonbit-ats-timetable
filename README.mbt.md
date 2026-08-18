# moonbit-ats-timetable

MoonBit 列车自动监控（ATS）运行图调度与实时冲突检测器。

这是一个面向轨道交通 OCC（运营控制中心）工具链的、纯 MoonBit 实现的运行图分析库。它把车站、区间、车次、停站、进路资源和实时遥测统一成可校验的数据模型，并输出可解释的冲突告警、调度建议和 Web String Diagram 数据。

项目定位是“调度辅助与仿真前置校验器”，不是直接控制信号设备的安全关键控制器。所有 Hold、Skip、SpeedUp 和 SlowDown 建议都带有前置条件，必须由外部调度员或经过认证的控制系统复核后才能执行。

## 为什么做这个项目

Mooncakes 关键词检索覆盖了 train、railway、timetable、ATS、headway、conflict detection 和 dispatch。目前能找到的主要是通用 scheduler、cron、事件模拟和拓扑排序类包，没有发现面向轨道交通 ATS 运行图、区间追踪间隔、站台占用与咽喉进路冲突的一体化成熟项目。因此，本项目把通用调度算法落到一个边界清晰、可复用、具有真实应用价值的交通领域模型上，不复制现有 MoonBit 生态项目的功能边界。

## 功能

- 运行图建模：线路、站点、区间运行时间、早晚点容限、车次、停站、站台和进路资源。
- 交换格式：派生 JSON 序列化/反序列化，以及一个文档化的轻量 XML 交换子集。
- 静态校验：唯一标识、站点里程、区间运行约束、停站时序、平台和资源引用。
- 时空冲突检测：
  - 里程—时间斜线区间上的区间追踪/Headway Conflict；
  - 同站同站台占用交叉；
  - 咽喉、道岔和进路资源预约重叠。
- 实时监控：遥测合并、延误增长、位置跳变、乱序数据、未知车次和陈旧数据告警。
- 调度建议：基于优先级、运行时间余量和安全边界的 Hold、Skip、SpeedUp、SlowDown 候选排序。
- 可视化接口：String Diagram JSON 帧、NDJSON 增量流、冲突 CSV 和 SVG 展示辅助。
- 可复现演示：合成线路、故障遥测、确定性回放、健康指标和计划复核报告。

## 快速开始

需要 MoonBit 0.10.3 或更新版本。本仓库开发和验证使用 0.10.7。

~~~text
moon check --target all --deny-warn
moon test --target native --deny-warn
moon run --target native cmd/ats-demo -- --action conflicts
~~~

CLI 入口提供以下动作：

~~~text
moon run --target native cmd/ats-demo -- --action check
moon run --target native cmd/ats-demo -- --action conflicts
moon run --target native cmd/ats-demo -- --action diagram
moon run --target native cmd/ats-demo -- --action xml
moon run --target native cmd/ats-demo -- --action metrics
moon run --target native cmd/ats-demo -- --action simulate --json
moon run --target native cmd/ats-demo -- --action health
~~~

conflicts 会打印按严重度排序的告警摘要，diagram 输出浏览器可以直接消费的 JSON，simulate 运行确定性遥测回放。

## 库 API 示例

~~~mbt check
///|
test {
  let schedule = demo_schedule()
  inspect(validate_schedule(schedule).length(), content="0")
  let conflicts = detect_conflicts(schedule)
  inspect(conflicts.length() > 0, content="true")
  inspect(
    schedule.train_by_id("T101").unwrap().service_name,
    content="快车 101",
  )
}
~~~

JSON 和 XML 均使用同一组公开模型：

~~~text
let json_text = schedule.to_json_text()
let json_schedule = schedule_from_json_text(json_text)
let xml_text = schedule.to_xml_text()
let xml_schedule = schedule_from_xml_text(xml_text)
~~~

实时接入的最小路径：

~~~text
let monitor = Monitor::new(schedule)
monitor.ingest(event)
let snapshot = monitor.snapshot(at_min)
let conflicts = monitor.conflicts(at_min)
let decisions = monitor.dispatch_plan(at_min)
~~~

## 设计

~~~text
公开模型 / types.mbt
       |
       +--> validation.mbt       静态不变量与结构化问题
       +--> serialization.mbt    JSON/XML 交换边界
       +--> conflicts.mbt        运行图几何与资源区间
       +--> monitor.mbt          实时状态与告警
       +--> strategy.mbt         约束过滤与调度建议
       +--> renderer.mbt         JSON/NDJSON/CSV/SVG 展示 DTO
       +--> analytics.mbt        负载、延误和健康指标
       +--> planning.mbt         计划复核、时刻调整和释放门
       +--> demo.mbt             合成场景与确定性回放
       +--> cmd/ats-demo         可运行命令行示例
~~~

核心算法只使用整数分钟和整数米，避免浮点误差影响边界判断。冲突检测按区间相交和最小间隔计算，复杂度为当前运行图规模下可接受的 O(T²S + R²)，其中 T 是车次数、S 是区间数、R 是资源预约数。它适合离线校验、演练和中等规模实时快照；超大线网可在适配层按时间窗或资源分片。

## 输入边界

to_xml_text 和 schedule_from_xml_text 定义的是本项目的轻量交换子集，便于将已有 ATS/TMS 转换器接入；它不是对某家厂商私有 XML schema 的兼容承诺。生产接入应在边界层完成字段映射、单位确认、时区处理和设备数据鉴权。

## 测试与 CI

本地验证顺序：

~~~text
moon fmt --check
moon check --target all --deny-warn
moon test --target native --deny-warn
moon test --target all --deny-warn
moon info
~~~

.github/workflows/check.yml 参考 moonbit-community/.github/workflow-templates/check.yml 和社区项目的 test.yml，覆盖 Linux、macOS、Windows，并执行：

- MoonBit 工具链版本输出和依赖更新；
- moon check --target all --deny-warn；
- moon test --target all --deny-warn；
- moon fmt --check 与工作区无格式差异；
- moon info 与生成接口无差异。

当前 MoonBit 0.10.7 的 fmt/info 子命令不提供 deny-warn 选项，因此由前置 check/test 完成严格告警门禁，再执行官方模板使用的 fmt/info 检查。

## 许可证与来源

本项目采用 Apache-2.0，详见根目录 LICENSE。核心源码为本仓库原创 MoonBit 实现，没有复制 ATS 商业软件、私有代码、闭源代码或来源不明的生成内容。运行时只使用 MoonBit 官方核心 JSON 包；CI 中使用的 MoonBit 工具链安装脚本和 GitHub Actions 是构建基础设施，不是项目运行时依赖。

演示线路、车次、遥测和故障数据均为合成数据，不对应任何真实线路、时刻表或运营机构。没有引入第三方图片、字体或测试素材。

## 参赛申报范围

本阶段交付了可运行的库、CLI、测试、仿真和文档。后续可扩展：

1. 标准 TMS/ATS 适配器和可插拔字段映射；
2. WebSocket 或事件总线实时推送；
3. 折返、交路、站台股道和多线联络约束；
4. 更大规模线网的资源分片与增量检测；
5. 发布到 mooncakes.io 的版本化包。

项目不包含自动驾驶、信号机控制和联锁逻辑；这些内容应由符合铁路安全标准的专用系统承担。

## 维护说明

提交模型变化时，请同步增加黑盒测试、README 示例或 docs/ 设计说明，并运行 moon fmt --check、moon check、moon test 和 moon info。如果增加第三方实现或测试数据，必须在 README 或专门的来源文件中写明原项目、链接、许可证和使用范围。

*** Add File: README.md
# moonbit-ats-timetable

MoonBit 列车自动监控（ATS）运行图调度与实时冲突检测器。

这是一个面向轨道交通 OCC（运营控制中心）工具链的、纯 MoonBit 实现的运行图分析库。它把车站、区间、车次、停站、进路资源和实时遥测统一成可校验的数据模型，并输出可解释的冲突告警、调度建议和 Web String Diagram 数据。

项目定位是“调度辅助与仿真前置校验器”，不是直接控制信号设备的安全关键控制器。所有 Hold、Skip、SpeedUp 和 SlowDown 建议都带有前置条件，必须由外部调度员或经过认证的控制系统复核后才能执行。

## 为什么做这个项目

Mooncakes 关键词检索覆盖了 train、railway、timetable、ATS、headway、conflict detection 和 dispatch。目前能找到的主要是通用 scheduler、cron、事件模拟和拓扑排序类包，没有发现面向轨道交通 ATS 运行图、区间追踪间隔、站台占用与咽喉进路冲突的一体化成熟项目。因此，本项目把通用调度算法落到一个边界清晰、可复用、具有真实应用价值的交通领域模型上，不复制现有 MoonBit 生态项目的功能边界。

## 功能

- 运行图建模：线路、站点、区间运行时间、早晚点容限、车次、停站、站台和进路资源。
- 交换格式：派生 JSON 序列化/反序列化，以及一个文档化的轻量 XML 交换子集。
- 静态校验：唯一标识、站点里程、区间运行约束、停站时序、平台和资源引用。
- 时空冲突检测：区间追踪间隔、同站同站台占用、咽喉/道岔/进路资源预约重叠。
- 实时监控：遥测合并、延误增长、位置跳变、乱序数据、未知车次和陈旧数据告警。
- 调度建议：Hold、Skip、SpeedUp、SlowDown 候选排序与安全前置条件。
- 可视化接口：String Diagram JSON 帧、NDJSON 增量流、冲突 CSV 和 SVG 展示辅助。
- 可复现演示：合成线路、故障遥测、确定性回放、健康指标和计划复核报告。

## 快速开始

需要 MoonBit 0.10.3 或更新版本。本仓库开发和验证使用 0.10.7。

~~~text
moon check --target all --deny-warn
moon test --target native --deny-warn
moon run --target native cmd/ats-demo -- --action conflicts
~~~

~~~text
moon run --target native cmd/ats-demo -- --action check
moon run --target native cmd/ats-demo -- --action conflicts
moon run --target native cmd/ats-demo -- --action diagram
moon run --target native cmd/ats-demo -- --action xml
moon run --target native cmd/ats-demo -- --action metrics
moon run --target native cmd/ats-demo -- --action simulate --json
moon run --target native cmd/ats-demo -- --action health
~~~

## 设计

公开模型位于 types.mbt，其余模块分别负责 validation、JSON/XML serialization、conflicts、monitor、strategy、renderer、analytics、planning 和 demo。核心算法只使用整数分钟和整数米，避免浮点误差影响边界判断；离线和中等规模实时快照下，冲突检测复杂度为 O(T²S + R²)。

## 测试与 CI

.github/workflows/check.yml 参考 MoonBit 社区 workflow template，覆盖 Linux、macOS、Windows，并执行 moon check --target all --deny-warn、moon test --target all --deny-warn、格式化检查和 moon info --deny-warn。

## 许可证与来源

本项目采用 Apache-2.0，详见根目录 LICENSE。核心源码为本仓库原创 MoonBit 实现，没有复制 ATS 商业软件、私有代码、闭源代码或来源不明的生成内容。演示线路、车次、遥测和故障数据均为合成数据，不对应任何真实线路或运营机构。

项目不包含自动驾驶、信号机控制和联锁逻辑；这些内容应由符合铁路安全标准的专用系统承担。
