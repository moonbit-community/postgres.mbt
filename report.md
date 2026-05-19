# 公开 API 设计审查报告

本报告审查 `moonbit-community/postgres` 的公开 API 设计，重点看生成的
`.mbti` 接口文件、README 示例，以及定义导出类型和方法的源码。

结论很直接：这套 API 能用，但设计上把太多实现细节推给了用户。用户在安全地
完成基本查询之前，就被迫理解连接驱动、流清理、池化租约、取消语义和 wire
protocol 内部结构。还有不少命名看起来像临时兼容补丁，而不是经过认真设计的
公开词汇。

## 1. `connect` 暴露了手动驱动运行时的模型

当前 API：

- `@client.connect(config) -> (Client, Connection)`
- 调用方必须在后台任务里运行 `Connection::run()`，否则 `Client` 不会推进 I/O。

问题：

最容易被用户发现的入口 API 不是完整可用的。用户可以成功调用 `connect`，拿到
`Client`，再调用 `query_one`，然后程序永远挂住，因为真正拥有 socket 的
`Connection` 没有运行。

具体场景：

服务作者写了一个很短的脚本：

```mbt
let (client, _) = @client.connect(config)
let row = client.query_one("select 1::int4")
```

这段代码能通过类型检查，而且看起来完全合理。运行时查询却永远不返回，因为被
忽略的 `Connection` 才是真正的 I/O 驱动。API 允许用户构造出一个“不工作但看
起来正常”的 client，却没有在命名上提示这是手动模式。

建议方向：

让安全主路径接管 task group：

- `connect(config, group) -> Client`
- `connect_manual(config) -> (Client, Connection)` 留给高级用户

手动拆分的运行时模型可以存在，但不应该是主入口。

## 2. 公开 struct 字段泄漏了内部不变量

当前 API 示例：

- `Row { columns, values }`
- `RowStream { mut columns }`
- `Config { ... }`
- `Statement { params, columns }`
- `Portal { columns }`

问题：

这些字段承载的是驱动内部不变量，但 API 允许用户直接观察，甚至在某些情况下
构造非法状态。公开字段不是文档，它是兼容性承诺。

具体场景：

测试 helper 构造一个假 row：

```mbt
let row : @client.Row = {
  columns: [some_column],
  values: [],
}
```

这个 row 是非法的，因为 `columns.length()` 和 `values.length()` 不一致。后面
调用 `row.get(0)` 时，会在 `values` 索引处失败，看起来像 decoder 的问题。其
实根因是 API 允许普通用户构造出不该存在的值。

另一个场景：

用户在 row 还没流完时读取 `stream.columns`。因为 `columns` 会在收到
`RowDescription` 后变化，提前缓存它的代码可能拿到空元数据或过期元数据。这是
内部状态转换被公开字段泄漏了。

建议方向：

字段私有化，提供 accessor：

- `Row::columns() -> ArrayView[Column]` 或类似只读视图
- `Row::raw_values()` 只在确实支持 raw access 时提供
- `RowStream::columns()` 明确说明这是“当前已知的最新 columns”
- 只提供能校验不变量的构造器，或者把构造 helper 限定在测试中

## 3. `protocol/*` 内部实现被发布成用户 API

当前 API 示例：

- `protocol/types`: `int4_to_sql`, `array_to_sql`, `range_to_sql` 等
- `protocol/message/frontend`: `bind`, `parse`, `execute`, `startup_message`
- `protocol/authentication`: `hi`, `normalize`, `ScramSha256::new_inner`
- `protocol/crypto`: `sha256_bytes`, `hmac_sha256`, `hex_encode`

问题：

这些是 wire protocol 构件，不是稳定的应用层 API。把它们公开出去，等于把每个
二进制表示、helper 名称和复杂 callback 编码签名都变成兼容性负担。

具体场景：

用户写了一个扩展包，直接 import `moonbit-community/postgres/protocol/types`，
并调用 `array_to_sql`。之后 client 想调整 array 编码以支持多维数组、domain
array 或 text-format fallback。即使高层 client API 本来可以保持稳定，底层
helper 的公开签名也会让这次改动变成 breaking change。

另一个场景：

有人看到 `protocol/authentication.ScramSha256::new_inner` 是 public，就在一个
无关认证 helper 中使用它。这个名字给人的感觉是“受支持的构造器”，但它实际更像
实现钩子。以后任何 SCRAM 重构都可能破坏本不该依赖它的用户代码。

建议方向：

按受众拆分包：

- 公开高层 client/pool 包
- 只有在明确承诺支持时，才公开低层 protocol 包
- client 使用的 protocol 实现应尽量放在 private/internal API 中

如果 MoonBit 包机制让真正的私有子包比较困难，也应该大幅收缩导出名称。

## 4. `client` 和 `pgpool` 使用了不同的查询词汇

当前 API：

- `@client.Client::query(...) -> RowStream`
- `@pgpool.Client::query_all(...) -> Array[Row]`
- `@pgpool.Client` 没有 `query(...)`，流式查询变成 `with_stream(...)`

问题：

同一个项目对同一类用户意图使用了不同词汇。在 raw client 包中，`query` 表示
“流式读取 rows”。在 pool 包中，安全主路径是 `query_all`，流式访问则变成回调
式 API。

具体场景：

用户先从 `@client` 开始：

```mbt
let stream = client.query("select * from users")
```

后来为了连接复用迁移到 `@pgpool`，自然会尝试：

```mbt
pool.with_client(client => client.query("select * from users"))
```

结果没有这个方法。正确写法要么是 `query_all`，要么是 `with_stream`，取决于
所有权和生命周期。迁移概念上很简单，API 词汇却变了。

建议方向：

全项目统一命名：

- `query_stream` 表示流式查询
- `query_all` 表示收集所有行
- `query_one` 表示必须正好一行
- `query_opt` 表示零行或一行

如果 pool 需要强制 callback 作用域，可以叫 `with_query_stream`。

## 5. 同一概念的错误契约不一致

当前行为：

- `@client.Client::query_one` 抛 `ClientError::RowCount`
- `@pgpool.Client::query_one` 转发底层 client 行为
- `@pgpool.Transaction::query_one` 抛 `PoolError::RowCount`
- `@pgpool.PreparedStatement::query_one` 抛 `PoolError::RowCount`

问题：

方法名承诺了同一行为，但错误类型取决于调用者手里的 handle 类型。

具体场景：

应用代码有一个 helper 捕获“不是正好一行”的情况：

```mbt
try {
  client.query_one(sql)
} catch {
  @client.ClientError::RowCount(_) => ...
}
```

后来同一个 helper 被泛化到 pooled transaction 中使用。现在 row-count 失败变成
`@pgpool.PoolError::RowCount`，旧 catch 分支接不住。业务语义没变，只是 handle
类型变了，错误合同却变了。

建议方向：

选择一个 row-count 错误来源。建议 PostgreSQL 查询语义继续使用 client-level
错误，`PoolError` 只表达池生命周期问题，例如 pool closed、timeout、lease 和
operation scope。

## 6. 取消 API 作用域过宽，还泄漏敏感细节

当前 API：

- `Client::cancel_token() -> CancelToken`
- `CancelToken::cancel()`
- `CancelToken::process_id()`
- `CancelToken::secret_key()`

问题：

低层 cancel token 是 connection-scoped 且长期有效的。它会取消“之后某个时刻该
连接上正在运行的操作”，不一定是用户原本想取消的那个操作。它还公开了 PostgreSQL
backend secret key。

具体场景：

一个 timeout helper 把 `client.cancel_token()` 存到队列里。原查询很快完成，但
排队的 timeout 任务稍后才执行并调用 `cancel()`。这次 cancel 可能打断同一个
connection 上后来的另一个查询。

另一个场景：

调试日志写了：

```mbt
println(token.secret_key())
```

API 把 server-side cancellation secret 包装成了普通可读诊断字段。除非理由非常
强，否则它不应该出现在公开 API 上。

建议方向：

默认提供作用域化取消，就像 pool 已经通过 `run_cancellable` 做的那样。raw
client 也应该有 operation-scoped API。`secret_key()` 应删除，或移动到明确标注
为 unsafe/internal 的 API。

## 7. Config 形状扁平、过载，而且命名不一致

当前 API 问题：

- `client.Config` 使用 `database`
- `pgpool.Config` 使用 `dbname`
- `Config::from_parts` 有 14 个位置参数
- `pgpool.Config` 把 `host`、`hosts`、`hostaddr`、`hostaddrs`、`port`、`ports`
  都平铺在一个结构中

具体场景：

用户从 raw client config 迁移到 pool config：

```mbt
@client.Config::new("localhost", user="moon", database="app", ...)
@pgpool.Config::new("localhost", user="moon", dbname="app", ...)
```

同一个概念换了名字。这是纯粹的摩擦。

另一个场景：

pool 用户想配置两个 host，并为每个 host 指定地址：

```mbt
Config::new(
  "primary.db",
  hostaddr="10.0.0.1",
  hosts=["replica.db"],
  hostaddrs=["10.0.0.2"],
  ports=[5432],
  ...
)
```

现在用户必须理解 append order、broadcast 规则，以及多个 optional 字段之间的
arity 校验。长度错误要到 normalize 阶段才发现，类型系统没有帮忙表达这个约束。

最糟糕的是 `Config::from_parts`：两个相邻 string 参数写反，也可能仍然通过类型
检查，因为大多数字段都是 `String` 或 `String?`。

建议方向：

引入明确的 target 类型：

```mbt
struct ConnectionTarget {
  host : String
  hostaddr : String?
  port : Int
}
```

pool config 接收 `targets : Array[ConnectionTarget]`，而不是一团扁平的
libpq-style 字段。同时统一使用 `database` 或 `dbname`，不要两个都用。

## 8. `Timeouts::new` 使用了双层 optional 参数

当前 API：

```mbt
pub fn Timeouts::new(
  wait_ms? : Int? = None,
  create_ms? : Int? = None,
  recycle_ms? : Int? = None,
) -> Timeouts
```

问题：

参数本身是 optional，参数值又是 optional。这会把调用点变成难看的
`wait_ms=Some(500)`。

具体场景：

用户自然会写：

```mbt
Timeouts::new(wait_ms=500)
```

但这不匹配公开签名。README 必须专门教用户写 `wait_ms=Some(500)`，这说明构造器
是围绕内部表示设计的，不是围绕用户意图设计的。

另一个场景：

因为 `Timeouts` 字段是 public，用户可以直接构造：

```mbt
{ wait_ms: Some(-1), create_ms: None, recycle_ms: None }
```

非法值只有在 `PoolConfig::new`、`Pool::get` 或 `Pool::timeout_get` 中才被拒绝。

建议方向：

使用普通 optional named arguments：

```mbt
Timeouts::new(wait_ms? : Int, create_ms? : Int, recycle_ms? : Int)
```

或者使用 builder，例如 `.wait_ms(500)`。构造时就完成校验。

## 9. Transaction 选项在 pool 中强类型，在 client 中却是字符串

当前 API：

- `@client.TransactionBuilder::isolation_level(String)`
- `@pgpool.TransactionBuilder::isolation_level(IsolationLevel)`

问题：

pool 这里的 API 反而更好。raw client 对一组很小的 PostgreSQL isolation level
使用任意字符串。

具体场景：

用户写：

```mbt
client.build_transaction().isolation_level("SERIALIZBLE").start()
```

拼写错误能通过类型检查，只会在 PostgreSQL 解析生成的 `BEGIN` 语句时失败。pool
版本用 `IsolationLevel::Serializable` 可以直接避免这种错误。

建议方向：

把 `IsolationLevel` 移到 client 包中，让 client 和 pool 都使用同一个 enum。如
果确实需要逃生口，提供一个命名明确的 `isolation_level_raw(String)`。

## 10. `query_typed_raw` 这个废弃别名还在主接口面上

当前 API：

- `Client::query_typed(...)`
- `Client::query_typed_raw(...)`，文档说它只是 backward-compatible alias

问题：

带有 `raw` 的旧别名仍然会出现在生成文档和 IDE 补全中，即使新用户不应该用它。

具体场景：

用户浏览补全时看到 `query_typed` 和 `query_typed_raw`。因为 `raw` 经常意味着
“更底层、更直接”，用户反而可能选择 `query_typed_raw`，并不知道 README 里说新
代码应优先用 `query_typed`。

建议方向：

如果 MoonBit 支持 deprecation metadata，就标记 deprecated。把它移动到
`deprecated.mbt`，并在下一个 breaking 版本移除。

## 11. `execute_raw` 命名错误

当前 API：

- `Client::execute(sql, params?)`
- `Client::execute_raw(statement, params?)`

问题：

`execute_raw` 并不执行 raw SQL。它执行的是已经 prepared 的 `Statement`。这个
名字既没有描述输入，也没有描述安全模型。

具体场景：

用户想执行无参数 raw SQL，看到 `execute_raw`，可能期待这样写：

```mbt
client.execute_raw("vacuum analyze")
```

但方法需要的是 `Statement`，于是用户必须反向理解：“raw” 在这里其实是
“prepared statement path”。这是糟糕命名。

建议方向：

改名为 `execute_statement`。它应该和已经更清楚的 `query_statement` 配对。

## 12. `get_name` 听起来像是在获取名字

当前 API：

- `Row::get_name(name)`
- `Row::get_raw_name(name)`
- `Row::get_text_name(name)`
- `SimpleQueryRow::get_name(name)`

问题：

这些名字读起来像“获取 name 属性”，而不是“按列名取值”。

具体场景：

用户代码里：

```mbt
let value : Int = row.get_name("id")
```

只有在熟悉这个库之后才知道它是什么意思。脱离上下文看，`get_name` 更像返回 row
的名字，而不是返回名为 `"id"` 的字段。

建议方向：

让名字直接表达 lookup mode：

- `get_by_name`
- `get_raw_by_name`
- `get_text_by_name`
- `try_get_by_name`

## 13. `Type::name_type` 和 `Type::oid_type` 是命名补丁

当前 API：

- `Type::name_type()`
- `Type::oid_type()`

问题：

这些后缀存在，是因为 `Type::name` 和 `Type::oid` 已经是字段。这说明 `Type` 这
个类型名本身过于泛化，逼出了难看的构造器命名。

具体场景：

用户想为 PostgreSQL `oid` 显式指定参数类型：

```mbt
client.prepare_typed("select $1::oid", [@client.Type::oid_type()])
```

双重 `type` 看起来笨拙又随意，而且 PostgreSQL 类型名本身反而不够清楚。

建议方向：

把描述符类型改名为 `PgType`。这样构造器可以自然命名：

- `PgType::name()`
- `PgType::oid()`
- `PgType::int4()`

如果重命名 `Type` 太破坏兼容性，就添加更好的别名，并废弃旧构造器。

## 14. `Kind` 和 `Field` 太泛

当前 API：

- `Kind`
- `Field`

问题：

这些名字从 client 包导出，但它们只在 PostgreSQL 类型元数据语境中有意义。泛名
会增加命名冲突，也让 import 后的代码可读性变差。

具体场景：

应用代码里已经有业务域的 `Field` 类型，例如表单字段或 JSON schema 字段。再
import `@client.Field` 时就产生命名冲突，而这个类型本该通过名字明确说明它是
composite type field。

建议方向：

改名为：

- `TypeKind`
- `CompositeField`

这样签名不依赖 package context 也能自解释。

## 15. `Pool::timeout_get` 词序别扭

当前 API：

- `Pool::get()`
- `Pool::timeout_get(timeouts)`

问题：

这个名字不清楚。它无法直接表达这是“获取当前 timeout 配置”、还是“带 timeout
的 checkout”、还是“用一组 override 执行 checkout”。

具体场景：

用户同时看到：

```mbt
pool.timeouts()
pool.timeout_get(...)
```

前者返回当前 timeout policy，后者用 override 执行 checkout。两个名字很接近，
但操作类别完全不同。

建议方向：

可选命名：

- `get_with_timeouts(timeouts)`
- `get_with_timeout(wait_ms)`
- `checkout(timeouts?)`

## 16. `Client::release` 对 pool lease 所有权来说太含糊

当前 API：

- `@pgpool.Client::release()`

问题：

`release` 没说释放的是什么，也没说释放到哪里。在 pool API 中，这个区别很重要：
释放 lease 意味着物理连接回到共享池中复用。

具体场景：

用户手动 checkout：

```mbt
let lease = pool.get()
lease.release()
```

这会关闭连接吗？归还到 pool 吗？把 lease 标成不可用吗？会先清理未完成状态吗？
名字没有回答这些基本生命周期问题，用户只能去读文档。

建议方向：

名字里应该体现所有权模型：

- `return_to_pool`
- `close_lease`
- `release_lease`

最安全的公开路径仍然应该是 `Pool::with_client`，但手动 API 也必须明确。

## 17. `run_cancellable`、`Operation` 和 `OperationCancelToken` 过于机械

当前 API：

- `Client::run_cancellable(f)`
- callback 收到 `(Operation, OperationCancelToken)`

问题：

这些名字描述的是实现机制，不是用户意图。这个 API 真正想表达的是：“运行一个
可取消的作用域化数据库操作，而且不会误伤后续 borrower”。

具体场景：

应用代码里：

```mbt
client.run_cancellable((op, token) => {
  ...
})
```

`Operation` 极其泛。它没有告诉读代码的人：`op` 是一个受限数据库 handle，绑定
在一个 cancellable scope 中，并且一次只允许一个 request。

建议方向：

考虑这些名字：

- `with_cancellable_client`
- `CancellableClient`
- `CancelHandle`

当前行为是有价值的；问题是命名没有把安全模型说清楚。

## 18. `GenericClient` 太泛，而且只存在于 `pgpool`

当前 API：

- `pub(open) trait GenericClient` 定义在 `pgpool`
- 只为 `pgpool.Client` 和 `pgpool.Transaction` 实现

问题：

名字叫 “generic client”，但 raw `@client.Client` 没有实现它，而且 trait 只包含
完全 materialized 的高层 helper。

具体场景：

用户想写一个 repository 函数，让它既能接受 raw client，也能接受 pooled client
或 transaction：

```mbt
async fn load_user[C : @pgpool.GenericClient](db : C, id : Int) -> User { ... }
```

这对 pool client 和 pool transaction 可用，但对 raw client 不可用。trait 名字
承诺的是跨包抽象，实际却没有做到。

建议方向：

要么把 trait 移到 client 包并一致实现，要么把它改成更准确的名字，例如
`PooledQueryExecutor`。

## 19. 低层 stream API 要求用户手动遵守清理纪律

当前 API：

- `RowStream::next`
- `RowStream::finish`
- `RowStream::detach`
- `SimpleQueryStream::finish`
- `CopyOutStream::finish`

问题：

文档正确提醒用户不要直接丢弃未完成 stream。但 API 仍然很容易让用户这样做，而
漏掉清理会阻塞同一连接上的后续请求。

具体场景：

用户只读第一行就提前返回：

```mbt
let stream = client.query("select * from huge_table")
let first = stream.next()
return first
```

剩余 server messages 仍然挂在这个 stream 后面。同一连接上的后续查询可能卡住，
直到响应被 drain。用户必须知道要调用 `finish()` 或 `detach()`。

建议方向：

raw client 包也提供 callback-scoped stream helper：

- `Client::with_stream(sql, params?, f)`
- `Client::query_all`

raw stream 可以保留为高级 API，但名字和文档必须强调所有权。

## 20. `ChannelBinding` 的 `Prefer` / `Require` 重新引入 TLS 命名歧义

当前 API：

- `SslMode` 刻意移除了 `Prefer` 和 `Require`
- `ChannelBinding` 仍然有 `Prefer` 和 `Require`

问题：

文档解释了二者区别，但熟悉 libpq 的用户仍然可能把 `sslmode=require` 和
`channel_binding=Require` 混淆。

具体场景：

用户读迁移文档，看到 `sslmode=require` 被移除了，随后又看到：

```mbt
channel_binding=Require
```

他们可能推断这会要求 TLS。实际不是；它控制的是 SCRAM channel binding，而且本
身不会启用 TLS。

建议方向：

使用更明确的 variant 名：

- `ChannelBinding::Disabled`
- `ChannelBinding::Preferred`
- `ChannelBinding::Required`

或者直接把 enum 改名：

- `ScramChannelBinding::Disable`
- `ScramChannelBinding::Prefer`
- `ScramChannelBinding::Require`

相比 variant，重命名 enum 更重要。

## 优先修复列表

如果这套 API 还没有稳定发布，建议在严肃版本前优先处理这些问题：

1. 让安全的 client 连接 API 自动驱动 `Connection::run`。
2. 隐藏 `Row`、`RowStream`、config、statement 和 portal 类型上的可变/内部字段。
3. 删除或明确隔离 `protocol/*` 内部实现，避免把它们当成受支持公开 API。
4. 统一 raw client 和 pool 的 query 命名。
5. 统一 client、pool client、transaction 和 prepared statement helper 的
   row-count 错误类型。
6. 用作用域化 cancellation 取代 connection-wide cancellation 作为推荐 API。
7. 重新设计 config target 模型，不要继续使用扁平 optional host 数组。
8. 清理明显命名债：`execute_raw`、`query_typed_raw`、`get_name`、
   `Type::oid_type`、`Kind`、`Field`、`timeout_get` 和 `release`。

