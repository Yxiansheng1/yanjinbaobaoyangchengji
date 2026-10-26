# 情侣看看

两个人互相看见对方在哪、在用什么、什么时候睡。

## 文档

| 文件 | 用途 |
| --- | --- |
| `docs/情侣看看-规格-v0.1.html` | **施工依据**。契约层，v0.1.5，按它派工单 |
| `docs/001-schema.sql` | 建库脚本，已在 Supabase 执行 |
| `docs/002-contract.sql` | 幂等索引、上报函数、状态视图。已在 Supabase 执行 |
| `docs/003-hardening.sql` | 权限收口、关系唯一性、快照版本、纯查看模式、客户端直写收口。已部署，结构校验通过，线上行为待验证 |
| `docs/情侣看看-PRD-v1.0.html` | 产品意图，64 项功能与分期 |
| `docs/PRD与Spec修改意见-2026-10-26.md` | 第一轮外部审查，R01 到 R12 |
| `docs/修改意见处理-2026-10-26.md` | 第一轮逐条处置 |
| `docs/我的意见-2026-10-26.md` | 我对第一轮审查的立场 |
| `docs/PRD与Spec二次复核-2026-10-26.md` | 第二轮复核，N01 到 N09 |
| `docs/PRD与Spec二次复核-本地验证结果.json` | 第二轮复核方的 PGlite 证据 |
| `docs/二次复核处理-2026-10-26.md` | 第二轮逐条处置与本机验证结果 |
| `docs/PRD与Spec三次复核-2026-10-26.md` | 第三轮复核，T01 到 T04 |
| `docs/PRD与Spec三次复核-本地验证结果.json` | 第三轮复核方的 38 项结果 |
| `docs/verify-003-third-review.mjs` | 第三轮复核方的补充脚本，不替代正式脚本 |
| `docs/三次复核处理-2026-10-26.md` | 第三轮逐条处置 |
| `docs/verify-003.mjs` | 可复现的本机验证脚本，37 项断言 |
| `docs/verify-003-results.json` | 上一条脚本本次跑出的结果 |
| `docs/情侣看看-v0.1-方案.md` | 早期草稿，已作废 |

冲突时取值顺序：SQL 大于规格，规格大于 PRD。

## 结构

- 她的安卓：Kotlin + Compose，采集全部数据，也能看对方
- 查看端：你的备用安卓机，纯查看模式，关闭采集与三类共享；iOS 排 v0.2
- 后端：Supabase 免费档，新加坡区域

## 三种状态

「设计好了」「脚本跑过了」「在线上验过了」是三件事，分开记。

| 部分 | 设计 | 已部署 | 已验证 |
| --- | --- | --- | --- |
| `001-schema.sql` | 完成 | 是 | 是：Auth 200、9 表存在、未登录调函数被拒、越权写入 42501 |
| `002-contract.sql` | 完成 | 是 | 是：两个上报函数存在且未登录被拒、`visible_status` 可读 |
| `003-hardening.sql` | 完成 | **是**：2026-10-26 线上执行，七行校验全 `true` | 部分：本地 `verify-003.mjs` 全过；线上结构校验通过；行为校验（V16–V21）未做 |
| 规格 v0.1.5 | 冻结 | — | — |
| 安卓代码 | 未开始 | — | — |

003 的结构部分已经上线；行为侧还有七项要验：未配对隔离、暂停全入口、Realtime 消息体、两连接快照并发、两连接配对并发、恢复与补传不返旧点、直写被拒。清单在 `docs/三次复核处理-2026-10-26.md`。全部跑完才能把 003 标成「已验证」。

## 环境

- JDK 17.0.2 在 `C:\Users\morel\AndroidDev\jdk`
- Android SDK 36、build-tools 36.0.0、Gradle 8.11.1 在 `C:\Users\morel\AndroidDev\`
- 调试签名 `C:\Users\morel\.android\debug.keystore`，SHA1 `87:A2:C1:AB:4B:23:1B:6E:A9:2C:83:DB:B4:C8:F0:1A:36:BE:FA:CB`
- 包名 `com.couplesee`，minSdk 28，targetSdk 36
- 密钥走 `android/local.properties`，不入仓库

## 还差什么

- 备用机的型号与 Android 版本：低于 Android 9 要回退 minSdk，并降级三项用机指标
- 003 行为侧七项校验（需要真实 JWT 与 Realtime 客户端）
- 正式签名 keystore
- pg_cron 是否启用：不启用时位置点不会自动过期
