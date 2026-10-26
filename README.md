# 情侣看看

两个人互相看见对方在哪、在用什么、什么时候睡。

## 文档

| 文件 | 用途 |
| --- | --- |
| `docs/情侣看看-规格-v0.1.html` | **施工依据**。契约层，冻结后按它派工单 |
| `docs/001-schema.sql` | 建库脚本，已在 Supabase 执行 |
| `docs/002-contract.sql` | 契约补丁，幂等索引、上报函数、可见性视图。**待执行** |
| `docs/情侣看看-PRD-v1.0.html` | 产品意图，64 项功能与分期 |
| `docs/情侣看看-v0.1-方案.md` | 早期草稿，已作废 |

冲突时取值顺序：SQL 大于规格，规格大于 PRD。

## 结构

- 她的安卓：Kotlin + Compose，采集全部数据，也能看对方
- 他的 iPhone：v0.2 之后再做，v0.1 只保证安卓侧跑通
- 后端：Supabase 免费档，新加坡区域

## 当前进度

- 数据库 001 已执行，鉴权、表、行级权限、配对函数四项验证通过
- 002 契约补丁待执行
- v0.1 规格已冻结，20 张工单待派
- 代码未开始

## 环境

- JDK 17.0.2 在 `C:\Users\morel\AndroidDev\jdk`
- 调试签名 `C:\Users\morel\.android\debug.keystore`，SHA1 `87:A2:C1:AB:4B:23:1B:6E:A9:2C:83:DB:B4:C8:F0:1A:36:BE:FA:CB`
- 包名 `com.couplesee`
- 缺 Android SDK 与 Gradle
