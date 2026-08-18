# 8 月黑客松项目申报书

**项目标识**：`moonbit-ats-timetable`  
**项目名称**：MoonBit 列车自动监控（ATS）运行图调度与实时冲突检测器  
**项目仓库**：<https://github.com/zhtzht12345678/moonbit-ats-timetable>  
**项目类型**：原创 MoonBit 工程，许可证为 Apache-2.0。

## 一、背景与应用价值

轨道交通调度中心（OCC）需要同时处理计划运行图、列车实时位置、站台占用和进路资源。现有运行图通常以静态文件存在，晚点、扣车、跳停或临时限速发生后，调度员需要快速判断追踪间隔、站台和咽喉资源是否产生冲突。本项目提供一个可嵌入的 MoonBit 调度分析库和 CLI，将运行图校验、实时监控、冲突解释和调度建议统一到可测试、可回放的模型中。系统只输出可解释的辅助决策，不直接控制信号、联锁或列车，适合作为教学演练、算法验证和 OCC 工具链的基础组件。

## 二、目标与实施范围

本阶段交付一套从数据输入到可视化输出的最小完整闭环：建模线路、车站、区间、车次、停站、站台及咽喉/进路资源；支持 JSON 与轻量 XML 交换；校验时间顺序、资源引用和运行图不变量；接收遥测并维护列车状态；检测 Headway、站台占用和路线资源冲突；按优先级和运行余量生成 Hold、Skip、SpeedUp、SlowDown 建议；输出 String Diagram 的 JSON/NDJSON、CSV 与 SVG 数据，并提供确定性故障仿真。

## 三、技术路线

项目采用纯 MoonBit 分层实现：`types` 管理领域模型和不变量，`validation` 生成结构化校验报告，`conflicts` 将列车运行表示为里程—时间区间并执行相交判定，`strategy` 在安全边界内过滤和排序调度候选，`monitor` 合并遥测并生成告警快照，`renderer` 和 `analytics` 输出渲染数据、负载指标与健康度报告，`planning` 支持计划复核和重排建议。时间计算使用整数分钟和确定性排序，避免浮点误差；所有演示数据均为合成数据。

## 四、当前成果与验证

仓库已形成 13 个可追溯本地提交，实际 Git 跟踪的 MoonBit 源码为 4,291 行，包含库代码、测试、CLI 和示例。已覆盖静态校验、JSON/XML 往返、三类冲突、实时告警、策略建议、渲染输出、指标分析和仿真回放等测试；`moon test --target all --deny-warn` 在 wasm、wasm-gc、js、native 四个目标下均通过 9/9。项目提供跨平台 CI、README 中的可运行示例及 `check`、`conflicts`、`metrics`、`simulate` 等 CLI 操作。

## 五、原创性与后续扩展

已在 Mooncakes.io 检索 railway、timetable、ATS、headway、conflict detection、dispatch 等关键词，未发现与本项目直接重合的成熟 ATS 运行图项目；本项目不是第三方 ATS 的移植，仅依赖 MoonBit 官方核心 JSON 包。后续可增加标准 TMS/ATS 适配器、事件总线或 WebSocket 接入、多线折返与临时限速、增量资源分片、Web 端交互式运行图和 mooncakes.io 发布版本，保持核心模型、算法与渲染接口的可复用性。
