# TODO

基于 2026-03-11 的代码 review，当前仓库需要优先处理以下问题。

## P0

- [ ] 修复 `scram_sha_256()` 和 `ScramSha256::new()` 使用可预测伪随机数生成 salt / nonce 的问题。
  - 位置: [src/protocol/password/password.mbt](/home/foo/works/postgres.mbt/src/protocol/password/password.mbt), [src/protocol/authentication/sasl/sasl.mbt](/home/foo/works/postgres.mbt/src/protocol/authentication/sasl/sasl.mbt)
  - 原因: 当前 `@random.Rand::new()` 默认不是密码学安全随机源，salt 和 nonce 可预测，弱化 SCRAM 密码存储与认证安全性。
  - 建议: 改为显式注入安全随机源，或提供必须由调用方传入随机字节的 API。

## P1

- [ ] 严格校验协议中的 `NULL` 长度，只接受 `-1`，拒绝其他负数长度。
  - 位置: [src/protocol/message/backend/backend.mbt](/home/foo/works/postgres.mbt/src/protocol/message/backend/backend.mbt), [src/protocol/types/types.mbt](/home/foo/works/postgres.mbt/src/protocol/types/types.mbt)
  - 现状: `DataRowRanges::next`、`HstoreEntries::next`、`ArrayValues::next` 把任意负长度都当成 `NULL`。
  - 风险: 损坏或恶意协议帧会被静默解释成空值，掩盖真实协议错误。

- [ ] 修正 SCRAM password normalization，不要把非 ASCII 密码直接回退为原始字节。
  - 位置: [src/protocol/authentication/sasl/sasl.mbt](/home/foo/works/postgres.mbt/src/protocol/authentication/sasl/sasl.mbt)
  - 现状: 仅支持 ASCII fast-path，非 ASCII 或控制字符直接 fallback。
  - 风险: 与标准 SASLprep 不兼容，可能导致合法密码认证失败，也可能放过本应拒绝的输入。

- [ ] 在 `path_from_sql` 解析阶段验证点数量和 payload 长度。
  - 位置: [src/protocol/types/types.mbt](/home/foo/works/postgres.mbt/src/protocol/types/types.mbt)
  - 现状: 未检查 `points >= 0`，也未检查 `buf.length() == 5 + points * 16`。
  - 风险: 非法输入被延迟到迭代时才报错，解析对象可处于不一致状态。

- [ ] 为手写 `HMAC-SHA256` / `MD5` 增加标准测试向量覆盖，必要时评估是否替换为成熟实现。
  - 位置: [src/protocol/crypto/crypto.mbt](/home/foo/works/postgres.mbt/src/protocol/crypto/crypto.mbt)
  - 风险: 这类安全敏感代码当前主要靠间接 happy-path 测试，回归风险偏高。

## P2

- [ ] 在 `array_to_sql` 中验证元素个数与维度乘积一致。
  - 位置: [src/protocol/types/types.mbt](/home/foo/works/postgres.mbt/src/protocol/types/types.mbt)
  - 现状: 允许序列化 shape 和元素数量不一致的数组。
  - 风险: 生成非法 Postgres binary array，错误由服务端或下游消费者兜底。

- [ ] 补充边界测试，覆盖当前测试缺失的异常路径。
  - 建议覆盖:
  - 可预测随机源导致重复 salt / nonce
  - 非 `-1` 的负长度
  - 非 ASCII SCRAM 密码
  - 非法 `path` 点数量和长度
  - 数组维度与元素数量不一致
