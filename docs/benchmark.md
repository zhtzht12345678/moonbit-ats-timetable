# Benchmark

基准由 `cmd/ats-bench` 现场生成。合成运行图是确定性的，不使用随机数；`conflicts`、`interval_queries`、`resource_overlaps`、`passenger_observations` 和 `checksum` 是工作负载计数，`elapsed_ms` 来自 MoonBit `@env.now()` 的原生主机毫秒时钟。

## Reproduction

```text
moon run --target native cmd/ats-bench --
```

本记录是在 2026-08-19（Asia/Shanghai）于 Windows 10.0.26200.0、AMD64 Family 25 Model 80 Stepping 0 机器上完成的，使用：

```text
moon 0.1.20260807 (4da23f8 2026-08-07)
moonc v0.10.7+bc794d341 (2026-08-11)
moonrun 0.1.20260807 (4da23f8 2026-08-07)
```

这是一次原生 debug 运行，未做预热；耗时会随机器负载变化，计数和校验和应保持一致。

## Observed output

```text
case|stations|trains|iterations|elapsed_ms|operations_per_ms|conflicts|interval_queries|resource_overlaps|passenger_observations|checksum
small|8|24|3|61|54|1872|48|1260|144|111769023
medium|16|72|2|3001|12|21672|64|15624|1008|154589001
large|24|144|1|55098|1|60624|48|46224|3168|1503168
```

`operations_per_ms` 是将四类工作负载计数之和除以实测毫秒数得到的整数吞吐参考，不是安全性能上限。大规模运行图的冲突枚举仍具有较高的二次项成本，生产线网应使用时间窗、资源分片或增量快照缩小查询范围。
