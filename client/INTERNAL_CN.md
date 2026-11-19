# 客户端运行时架构

公共 API 的用法见 `README.mbt.md`。

## 所有权模型

`Client::create(config)` 只分配共享队列、内置类型信息和可重复等待的就绪状态，
不会打开套接字。它返回可复制的 `Client` 和只能运行一次的 `ClientExecutor`。
调用方在任务组中启动 `run()`；执行器负责连接、认证、发布启动信息，然后运行
套接字驱动器。`Client::ready()` 与异步数据库操作都会等待启动完成；在此之前
同步读取参数或取消令牌会返回 `NotReady`。重复运行执行器返回
`ExecutorAlreadyStarted`。

建连流程持有传输连接，直到启动成功。TLS 协商、认证或启动协议失败，或者连接
超时，建连流程会关闭传输连接，再向所有就绪等待者报告同一个错误。
如果在执行器启动前关闭客户端，执行器不会打开套接字。

`Stream` 的 TLS 变体保留 `Tls` 和原始 `Tcp`。读写通过 `Tls` 完成。清理时先用
`Tls::close()` 释放 TLS 状态，再用 `Tcp::close()` 关闭传输连接。这两步都是同步调用，
任务取消或报错时也能完成。清理会跳过异步 TLS 关闭交互。

驱动器是私有的。共享状态只保存其任务句柄，使 `Client::close()` 可以在启动期间
或运行期间同步请求取消。执行器只在 `run()` 的局部作用域持有任务组。驱动器负责
所有套接字读取、普通前端消息写入，以及提示、通知和参数状态更新的发布。

启动和驱动器的常规读取都使用 `read_backend_message`。它先读取五字节头部并解析
`Header`，确认总长度未溢出且正文未超过单帧上限，再读取和分配正文。协议解析错误
转换为 `ClientError::Protocol`。头部校验失败时会关闭连接并唤醒等待者。
客户端在建连前检查资源预算是否为正数。

SCRAM 在连接前验证正数迭代预算；服务端十进制计数在乘加前检查溢出，
并在 PBKDF2 开始前检查上限。纯协议包通过 `HiState` 共享同步 `hi`/`update`
与隐藏的 `begin_update`/`advance_update` 计算状态，begin 不执行 HMAC。
Deriving 状态不允许读取最终消息、重复更新或完成认证。每批最多 256 次 HMAC，
包括 PBKDF2 和证明计算；startup 在每批结束后调用可取消的 `@async.pause()`，
最后一批也先让出再发送证明。连接超时和取消沿现有传输所有权路径清理。
协议包中的 SCRAM 错误在客户端边界转换为 `ClientError::Authentication`。

## 单操作执行不变量

一个 PostgreSQL 会话同一时刻最多运行一个逻辑操作。公共入口先按 FIFO 顺序获取
`OperationGate` 许可，再提交协议请求。等待期间取消时，队列移除该等待者。

许可覆盖整个逻辑操作。

- 预处理、参数类型查询、执行和清理共享同一个上下文
- 流持续持有上下文，直到 EOF、结束或转交给分离的排空任务
- COPY IN 持续持有上下文，直到完成或中止
- 事务持续持有上下文，直到提交或回滚
- 嵌套事务在各个保存点作用域之间传递同一个上下文

类型解析中的系统目录查询、临时语句清理等内部阶段都使用父操作的私有 `OpContext`。
重新调用公开的 `Client` 方法会等待父操作已经持有的许可。

## 递归类型元数据

`Type` 保存目录 schema：内置类型为 `Some("pg_catalog")`，未解析的
`Type::unknown` 为 `None`。`Kind::Array`、`Domain`、`Range` 携带完整子类型，
`Field.type_` 保存完整的复合字段类型。字段和元数据集合只读，结构化 `Eq` 包括
schema 和完整子类型。子描述符通过 `.oid` 提供对应的 OID。

每次根查询创建一张表，记录当前递归路径上的 OID。再次遇到表中已有的 OID 时，抛出
`UnsupportedRecursiveType(oid)`。`defer` 在成功、失败或取消时移除标记。
连接只缓存构造完成的描述符，供同级查询复用。`clear_type_cache()` 清除自定义类型元数据。
目录查询复用父操作的 `OpContext`。主类型查询查不到行或遇到 PostgreSQL 数据库错误时，
返回 `Unknown` 描述符。查询枚举标签或复合类型字段遇到数据库错误时，返回空列表。
传输、协议、解码和循环错误会向上传播，其中循环属于事务本地错误。

通用数组从 `Kind::Array(element)` 获取完整子类型，元素兼容性
检查和编解码都使用该描述符。二进制读取校验数组载荷中的元素 OID。
自定义标量编码器用于数组时必须输出二进制元素载荷，不受其单独使用时的 `format` 偏好
影响。内置字符串和 JSON/JSONB 数组支持空数组和 NULL 元素。编解码器不自动解包域，
不提供通用复合/range 编解码、公开类型注册表或多维数组支持。

## 驱动器与队列

驱动器在连接建立后的整个生命周期维持一个套接字读取任务，包括空闲时段。
提示、通知和参数更新会立即发布；普通响应经容量为一的队列交给请求循环。
请求循环每次处理一个 `Request`：

1. 接收并保留下一个已接受操作的请求
2. 写入该请求的前端协议字节
3. 将每条普通响应路由到该请求的有界响应队列
4. 持续处理，直到收到 `ReadyForQuery` 或到达该请求协议规定的终止状态
5. 转而处理下一个请求

普通请求的响应队列容量为八条消息。读取任务到请求循环的队列最多缓存一条消息。
消费者停滞时，队列通过背压限制套接字读取和内存占用。
由于同一时刻只执行一个操作，后续请求无法绕过停滞的消费者。

COPY IN 需要同时读写，输入队列最多容纳八个动作。PostgreSQL 进入 COPY 模式后，
驱动器为这一请求启动一个写入任务，处理数据、完成和中止动作。读取任务仍是唯一的
后端消息读取者。遇到提前到达的 `ErrorResponse` 时，驱动器把错误转发给 sink，
清空并关闭输入队列。写入任务写完当前帧后停止。驱动器等它结束，再转发最终的
`ReadyForQuery` 或开始下一请求。每条退出路径都取消并等待写入任务。
写入任务意外失败时，该连接的执行器保留原始错误，取消驱动器和读取任务，并结束活动
及排队请求。
连接池将物理连接错误限制在该连接内，不终止其他会话。
`CopyInSink::abort` 在标记 sink 结束前编码完整 `CopyFail`；`Fail` 动作携带已验证的
字节。含 NUL 的消息不会改变 sink 状态或所有权，后续显式或作用域清理仍可合法中止。

## 错误与 Notice 字段

`parse_database_error` 解析启动错误、操作错误以及连接建立后收到的 Notice。
启动期间会记录参数状态，跳过 Notice。连接池直接传递同一 `ClientError::Database`。
解析器保留 PostgreSQL 文档中的错误与 Notice 标签
`S/V/C/M/D/H/s/t/c/d/n/P/p/q/W/F/L/R`。未知标签仍在 UTF-8 校验后忽略。

`severity` 仅保存 `S`，`severity_nonlocalized` 仅保存 `V`，不会因字段顺序互相覆盖；
所有可选字段独立初始化为 `None`；缺失 `M` 时
仍使用 `"database error"` 默认消息。`schema`、`table`、`column`、`datatype` 和
`constraint` 的存在互不蕴含。`Debug` 和 `Eq` 包含所有字段，包括对象名、上下文和
源代码位置。

`P/p/L` 只接受 ASCII 十进制数字并解析为 `UInt`；空串、符号、分隔符、非数字、
溢出和为零的 `P/p` 统一抛出 `ProtocolError::InvalidInput`，`L` 可以为零。
`position` 是原查询中的一基字符索引；`internal_position` 是 `internal_query`
（`q`）中的一基字符索引。解析器不转换为字节偏移或 UTF-16 索引。
`where_`（`W`）原样保存上下文及其中的换行。无效 UTF-8 也抛出 `InvalidInput`。

操作遇到 SQL 错误后，驱动器先排空至 `ReadyForQuery`，再恢复正常复用。
按 SQLSTATE 和约束名处理错误的示例见客户端 README；字段语义见
[PostgreSQL 错误与 Notice 协议](https://www.postgresql.org/docs/current/protocol-error-fields.html)。

## 流与分离

行流、简单查询流和 COPY OUT 流持有操作许可。

- 自然到达 EOF 时释放许可
- `finish()` 排空至操作边界，然后释放许可
- `detach()` 将响应队列和许可交给执行器控制队列调度的排空任务
- 分离后调用 `finish()` 会等待该排空任务完成

清理是幂等的。消费者取消后，清理仍持有许可，直到 PostgreSQL 到达可开始下一操作的
协议边界。

输出流向 pgpool 提供内部 `finish_scope`：等待协议完成及分离排空，将查询本身的
`DatabaseError` 作为返回值，传输、协议和资源清理失败仍抛出。公开 `next` 和
`finish` 仍抛出 SQL 错误。`StreamCleanup` 用一次性 `Completion` 保存临时语句
Close 的最终结果，包括失败；查询 summary 只能证明执行到达 ReadyForQuery，
不能证明 Close 成功。后续收尾必须等待并复用该结果，即使后台排空容忍了数据库异常。

正常读取和后台排空都以 `UInt64` 统计收到的 DataRow，通过
`QuerySummary.row_count` 返回。受影响行数来自命令标签中的十进制 `UInt64`。
无计数命令返回零，非法或超限计数抛出 `ClientError::Protocol`。
COPY IN 完成收集器读到 `ReadyForQuery` 后返回原始标签。`CopyInSink::finish`
先释放许可，再解析行数，以免解析失败后再次排空已经结束的响应队列。

六个 `Client::with_*` 流/COPY API 共用 `with_scoped_resource`。等待就绪和获取许可仍可
取消；仅协议启动和 finalizer 受到取消保护，业务回调保持可取消。资源获取后立即安装
`errdefer`，在回调前、回调后和清理后检查待处理取消。输出流调用 `finish()`；COPY IN
若未显式完成则调用 `abort()`。COPY IN 记录遗弃排空的完成信号，作用域因此也能等待
`send`、`finish` 或 `abort` 被取消时启动的后台清理。清理错误不覆盖回调原错误。
`Client::with_statement_stream` 和 `Transaction::with_statement_stream` 仅拥有
本次执行流，Statement 仍由调用方持有。`Portal::with_stream` 也只结束当前
分页流，portal 仍由外层 portal 作用域持有。

`read_prepare_response` 仅将参数 OID 和占位列描述读取到成功的 `ReadyForQuery`。
命名 prepare 和 inferred/typed 临时查询随后进入 `resolve_prepared_metadata`，先注册
语句清理，再解析参数和列。元数据失败时，在已有许可下关闭未交付的语句，并保留原始
解析错误；任何 Close 失败都会中止连接。Portal 列解析使用 portal 清理保护。

元数据解析成功后，临时查询在提交 Execute 前构造 Close 字节和执行参数，随后由不会
抛错的 RowStream 构造器接管清理责任。编码或提交失败时执行临时语句 Close，保留
原始错误。这条清理路径允许 Close 返回已同步的 SQL 错误，其他失败则关闭连接。

命名 `prepare` 使用专门的句柄交付路径：客户端或事务在受保护的准备过程结束后，仍持有
许可和 `OpContext`，然后检查待处理取消。若已取消，就受保护地发送 Close 并等待
`ReadyForQuery`，再传播取消。任何 Close 失败都会中止物理连接，但调用方仍收到原取消。

裸流工厂在获取许可后、开始协议工作前检查是否存在待处理的取消。对异步预处理或 COPY
启动过程施加取消保护的工厂，会在离开保护区域后、仍处于同一个 `errdefer` 作用域内时
再次检查。流尚未创建时，该作用域在失败后释放许可。流已创建时，取消会把流和许可交给
后台排空任务。

分离的流保存可重复等待的完成状态。执行器的控制任务独立接收
排空作业；即使八条消息的响应队列已满，驱动器也不会阻止排空调度。预期的 `Closed`
错误供 `finish()` 读取，不会使执行器失败。数据库错误保留在流状态中；意外错误会
使执行器失败。控制队列关闭后，`finish()` 会自行排空并取得结果或错误。
执行器退出时，控制队列也会向尚未开始的排空作业发布关闭结果，避免 `finish()`
无限等待。

`execute_raw` 取得结果流后，遇到错误或取消时会在保护下排空至 `ReadyForQuery`。
外层的 `execute` 随后关闭临时语句，避免在响应队列仍有背压时等待关闭。
清理保留原始错误或取消，调用方继续持有传给 `execute_raw` 的语句。
排空可能需要等待 SQL 执行完毕。要向 PostgreSQL 请求取消，由调用方发送 CancelRequest。

`Driver::run` 在正常关闭、普通错误和取消时，都会执行同步且幂等的退出清理。它会关闭
活动请求及排队请求的响应队列、COPY 输入队列、提交队列、通知队列和套接字，并将运行时
标记为已关闭。普通驱动器错误会传递给等待中的请求；取消则向这些请求传递
`ClientError::Closed`，同时保留驱动器自身的取消。驱动器退出时的 defer 清理会唤醒所有消费者，包括处于取消保护中的消费者。
执行器在局部任务和传输层清理结束后发布可重复等待的终态，且不会覆盖此前的失败。

## Statement 与 Portal 资源作用域

`Shared.connection_id` 由模块级同步 `UInt64` 计数器分配，与协议资源命名计数器独立；
耗尽时终止分配，禁止回绕。Client 副本、Statement 和同连接事务共享此身份。
接收 Statement 的公开入口在等待就绪、许可或注册资源前校验归属，`OpContext` 在执行、
绑定和关闭请求提交前复核。即使外部连接的 Statement 已关闭，仍返回
`StatementConnectionMismatch`，不提交请求、不改资源、不终止正常连接。
该错误属于事务本地错误，不触发协议失步处理。手动 Statement 仍可在同连接上跨事务
复用；`ScopedStatement` 的生命周期由回调作用域管理。

`Portal` 是唯一公开的 portal 句柄，直接持有事务、服务器名称、结果列、关闭标记、
作用域活动标记和活动调用计数。可变标记与计数仍使用共享引用，确保句柄副本观察到
相同的生命周期。作用域活动标记先拒绝新调用，已经开始的调用完成后才关闭服务器资源。
`Transaction::bind`、`query_portal`、`with_portal_stream` 和 `close_portal` 仍是包内
助手，通过协议和事务门控调用链执行。`OpContext::bind` 返回名称和解析后的结果列，
由 `Transaction::bind` 构造句柄；列类型解析失败时，先按名称关闭已绑定的 portal，
再传播错误。

通过 `Transaction::with_portal` 绑定普通 Statement，或通过事务内的
`ScopedStatement::with_portal` 创建 `Portal`。

每次 `Portal::with_stream` 返回前，都会在取消保护下将当前分页流排空至
`ReadyForQuery`。随后可通过同一 portal 继续获取下一页；`QuerySummary.suspended`
记录服务器的 `PortalSuspended`。`execute` 沿用此路径，并设置不限行数。
portal 清理仅关闭 portal，普通 Statement 仍可跨作用域、跨事务复用，连接池的
预处理语句缓存也不受影响。

回调退出时，资源作用域先拒绝新调用，等待通过该句柄已经开始的调用结束，再关闭资源。
已过期句柄的后续数据库操作报 `Closed`。嵌套资源先清理流，再关闭 portal，最后关闭语句。
回调保持可取消；finalizer 受取消保护，并保留回调原错误或取消。portal Close 失败
会中止连接并使事务失效。Bind 期间发生取消时，先关闭尚未交付的 portal，再释放作用域。

`scoped_resources` 在获取资源、执行回调和最终清理期间始终保持注册。显式提交或回滚
会拒绝仍有活动资源作用域的事务，包括存在于子事务中的作用域。回调式事务结束时，
会等待这些作用域完成，再执行流和子事务清理。

## 事务

开始事务时，许可从 Client 调用转移至 `Transaction`。事务方法使用同一个私有上下文。
提交或回滚完成后释放许可。连接失败导致事务失效时，也会释放许可。

通过外层 Client 的其他克隆提交的调用，会排在事务之后等待。嵌套事务使用保存点，
并将同一个上下文临时转交给子事务。

回调式事务在回调报错或取消时，在取消保护下尝试回滚，然后释放许可。
事务在交付流或子事务句柄前先登记该子操作。创建开始时设为 `Creating`，让并发关闭能
等待创建和清理完成。关闭时先拒绝新操作，再排空流或递归回滚子事务，最后获取作用域锁来
提交或回滚。提前获取锁会卡在子操作持有的许可上。流排空遇到数据库错误时，先受保护地
回滚再报告错误。传输或协议失败导致无法确认同步时，关闭物理连接。提交时若子事务仍未
结束，会递归回滚子事务和父事务，并报告 `UnfinishedChildTransaction`。

async 0.22 在离开受保护代码块时，不会自动传播待处理的取消。客户端和事务会在操作边界
检查取消：包括开始新工作之前，以及最外层保护结束之后。回调式事务还会在自动提交前
检查取消。如果调用者在外层设置了保护，这些检查会有意推迟到该保护自身的边界。
若 `BEGIN` 或 `SAVEPOINT` 成功后，在交付句柄前发生取消，则会在仍持有原始许可的
情况下执行回滚。对于已经提交给服务器的 `COMMIT`，会先排空响应并根据服务器结果
记录其状态，然后再传播取消。

## 异步消息

驱动器单独处理以下后端消息。

- `NoticeResponse`
- `NotificationResponse`
- `ParameterStatus`

读取任务收到 `ParameterStatus` 时更新共享参数。即使连接空闲，三类消息也会进入
Client 的异步消息队列。用一个消费者调用 `Client::next_message()`。启动成功后，
队列关闭且缓冲读完时返回 `None`。

`pgpool` 在启动物理连接前安装内部异步消息处理器。处理器将消息转发到连接池的缓冲
队列，调用方通过 `Pool::next_message()` 读取。

## 失败与关闭

启动后如果出现致命的套接字或协议错误，驱动器会执行以下步骤。

1. 使活动请求失败
2. 使已接受但尚未发送的请求失败
3. 让等待门控许可的操作获取许可，并观察到运行时已关闭
4. 关闭异步消息队列

`Client::shutdown()` 按 FIFO 顺序等待排在前面的操作完成，并拒绝后续工作。
如果启动还没完成，就停止启动。连接就绪时，提交 `Terminate` 并等待驱动器退出。
重复调用 `shutdown()` 会等待同一个结果。
提交后取消调用者，已入队的 `Terminate` 仍会交给驱动器处理。

`Client::close()` 会立即将运行时标记为已关闭，关闭提交队列但保留其中缓冲的请求记录，
并取消已保存的驱动器任务。随后，驱动器的资源释放流程会使活动响应队列和所有缓冲请求的
队列都以相同的 `ClientError::Closed("connection aborted")` 失败。驱动器靠保留的请求
记录通知排队的调用方。`is_closed()` 立即返回 true，此时驱动器可能还在关闭传输连接。

## 连接池请求监督

连接池持有操作锁时安装内部 RequestControl。每个协议请求都有独立的编号和记录。
驱动器在写入套接字前标记请求可能已发送，读取任务在转发消息前保存命令标签和协议
完成状态。取消后会拒绝 prepare、类型查询和执行等后续业务请求。Close 清理请求必须
等待取消屏障。CancelToken 等待单独的 TCP 连接读到 EOF，防止延迟的取消影响下一请求。
连接池还会等待原请求完成协议清理。客户端使用 FIFO 队列并支持手动事务。COMMIT
收到 ROLLBACK 标签时抛出 CommitRolledBack，缺少标签或标签无法识别时抛出
CommitOutcomeUnknown。明确的 PostgreSQL 错误会原样抛出。连接池根据读取任务的记录，
在丢失 ReadyForQuery 时仍能保留已确认的提交结果。
