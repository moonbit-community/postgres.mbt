我认为有 3 个确定缺陷，另有 2 个明显隐患。

  1. 高: SCRAM 密码规范实现和 PostgreSQL 标准并不一致，会在一部分非 ASCII 密码上直接造成认证/存储不兼容。sasl.mbt:10 明确写了“更接近现代 Unicode 行为而不是严格 RFC
     4013”；实现里做了 NFKC 和部分禁止字符检查，但没有完整 SASLprep 约束，尤其缺 bidi / unassigned 这类规则，sasl.mbt:19 sasl.mbt:37。更关键的是这套逻辑同时被客户端握手
     和密码摘要生成复用，sasl.mbt:241 password.mbt:25。结果是: 某些密码会“本库能算、Postgres 不认”或反过来。
  2. 中: SCRAM 的 i= 迭代次数完全由服务端控制且没有上限，存在明显 CPU DoS 面。sasl.mbt:481 解析出迭代次数后，sasl.mbt:289 直接喂给 PBKDF2，sasl.mbt:137 按次数做 HMAC 循
     环。恶意或异常服务端可以把客户端拖进超长计算。
  3. 中: range 二进制编解码接受并暴露了 PostgreSQL 不该存在的“NULL 边界”状态，属于协议层硬 bug。types.mbt:683 的编码 API 允许 Inclusive(IsNull::Yes) /
     Exclusive(IsNull::Yes)，并在 types.mbt:717 写出 -1 长度；解码时 types.mbt:766 把任何负长度都当成“无值边界”，连 -2 这种损坏数据也会被吞掉。公开类型面也把这种不合法
     状态暴露出去了，types.pkg.generated.mbti:218。
  4. 低: BOOL 解码过于宽松，任何非 0 字节都会被当成 true，会掩盖损坏或非规范数据。types.mbt:30 PostgreSQL 二进制 bool 实际上只该接受 0/1。
  5. 低: 有几个 serializer 能生成“自己的 parser 都会拒绝”的非法表示，属于调用即踩坑的隐患。varbit_to_sql 不校验 len 与实际字节数是否一致，types.mbt:306；但
     varbit_from_sql 会严格拒绝不匹配输入，types.mbt:320。inet_to_sql 也不校验 IPv4/IPv6 的 netmask 合法范围，types.mbt:1001，而 inet_from_sql 会拒绝越界值，
  补充

  - 我没把“UTF-8 假设”算成确定 bug，但它是个重要前提风险: utf8.mbt:3 types.mbt:57 backend.mbt:870。如果项目不强制 client_encoding=UTF8，现在这套字符串/文本接口会拒绝合
    法的非 UTF-8 PostgreSQL 部署。
  - 测试面偏 happy path。moon test 全绿，但没有覆盖上面这些负例，尤其是 range、bool、varbit、inet 和 frontend serializer。



  - src/protocol/message/backend/backend.mbt 重复实现了底层解析 helper，已经有公共实现却没有复用。find_null 在 bytes.mbt:183 和 backend.mbt:858 各写了一遍，read_cstr 已经在 bytes.mbt:196 封装好了，但 backend 里的 backend.mbt:326 backend.mbt:586 backend.mbt:774 还是走本地扫描。UTF-8 错误映射也重复了，utf8.mbt:3 和 backendmbt:870本质上是同一层逻辑。
  - src/protocol/types/types.mbt 职责明显过载，不是单纯“文件大”，而是把完全不同领域的 codec 全堆在一个文件里。标量类型从 types.mbt:23 开始，数组在 types.mbt:466，range
    在 types.mbt:681，几何类型在 types.mbt:873，网络地址在 types.mbt:1000，ltree 系列在 types.mbt:1075。这已经偏离了 MoonBit 项目里“按 feature 拆小文件”的组织方式。
  - src/protocol/authentication/sasl/sasl.mbt 里有一段很明显的“手写字节扫描器”风格，偏底层、偏命令式，不够 idiomatic。bytes_equal 和 starts_with 在 sasl.mbt:370
    sasl.mbt:383，take_while 和数字解析在 sasl.mbt:428 sasl.mbt:468。尤其 posit_number 这个命名本身就像笔误，说明这一段缺少整理。
  - src/protocol/message/frontend/frontend.mbt 多处用 try! write_body 构造固定格式、逻辑上不可能失败的消息，这会把“内部不可能出错”的路径伪装成 panic 式控制流。典型位置
    是 frontend.mbt:75 frontend.mbt:124 frontend.mbt:230 frontend.mbt:253 frontend.mbt:260 frontend.mbt:267。这类代码读起来会让人误判真实的错误边界。
  - src/protocol/message/backend/backend.mbt 后半段样板 getter 太多，文件可读性被大量“包装层”稀释了。比如 backend.mbt:399 backend.mbt:635 backend.mbt:715
    backend.mbt:807。这些不是错，但风格上偏“样板代码堆积”，维护成本高。