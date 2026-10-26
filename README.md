# 情侣看看

两个人互相看见对方在哪、在用什么、什么时候睡。

## 文档

| 文件 | 用途 |
| --- | --- |
| `docs/情侣看看-规格-v0.1.html` | **施工依据**。契约层，冻结后按它派工单 |
| `docs/001-schema.sql` | 建库脚本，已在 Supabase 执行 |
| `docs/002-contract.sql` | 幂等索引、上报函数、状态视图。已在 Supabase 执行 |
| `docs/003-hardening.sql` | 权限收口、关系唯一性、快照版本。**待执行** |
| `docs/情侣看看-PRD-v1.0.html` | 产品意图，64 项功能与分期 |
| `docs/PRD与Spec修改意见-2026-10-26.md` | 外部审查意见，R01 到 R12 |
| `docs/修改意见处理-2026-10-26.md` | 逐条处理结论与证据 |
| `docs/我的意见-2026-10-26.md` | 我对审查的立场：认的、顶回去的、新发现的 |
| `docs/情侣看看-v0.1-方案.md` | 早期草稿，已作废 |

冲突时取值顺序：SQL 大于规格，规格大于 PRD。

## 结构

- 她的安卓：Kotlin + Compose，采集全部数据，也能看对方
- 查看端：v0.1 方案未定，见规格第 15 节 R04
- 后端：Supabase 免费档，新加坡区域

## 当前进度

- 001 已执行。验证：Auth 200、9 表存在、配对函数未登录被拒、越权写入被 RLS 挡（42501）
- 002 已执行。验证：`report_locations` 与 `report_usage` 存在且未登录被拒、`visible_status` 可读
- 003 待执行。执行后要补五项验证，清单在 `docs/修改意见处理-2026-10-26.md`
- 规格 1.1 已冻结，待 R04 决策后派工单
- 代码未开始

## 环境

- JDK 17.0.2 在 `C:\Users\morel\AndroidDev\jdk`
- Android SDK 36、build-tools 36.0.0、Gradle 8.11.1 在 `C:\Users\morel\AndroidDev\`
- 调试签名 `C:\Users\morel\.android\debug.keystore`，SHA1 `87:A2:C1:AB:4B:23:1B:6E:A9:2C:83:DB:B4:C8:F0:1A:36:BE:FA:CB`
- 包名 `com.couplesee`，minSdk 28，targetSdk 36
- 密钥走 `android/local.properties`，不入仓库
