# 连接池实现约束

`PoolExecutor` 管理物理连接执行器以及建连、关闭任务。
checkout 只预留一个容量槽；交接前由 checkout 的异常清理归还，交接后只由
`Session::release` 归还。淘汰连接只修改物理连接计数，不能再次释放容量。
归还时完成全部重置后才能加入 idle 队列。
空闲连接出队后立即注册异常淘汰，再检查 recycle deadline，防止立即到期的
回收预算留下无人持有的物理连接。

Session 和 Transaction 共用 `ClientLeaseState`。业务操作先检查作用域有效性，
再以 `Mutex::try_acquire` 立即获取或拒绝，不排队。事务持有父 Session 的锁，
保存点持有父 Transaction 的锁；子作用域过期后才恢复父句柄。prepared 回调只
保留作用域计数，实际准备或执行时才加锁。流和 COPY 持有连接至回调退出，句柄
另外检查过期和重叠调用。逃逸到外层任务的活动操作会导致连接淘汰，不能进入下一次借用。

事务、prepared、stream/COPY 和 Session 归还共用 `with_scope_exit` 退出协议。
body 在可取消环境中执行，调用前后检查取消；局部 `errdefer` 受保护地执行
`on_unwind` 并忽略其异常，保留原回调异常或原生取消。正常返回则受保护地执行
`on_return`，将其普通异常保存为内部 `Result[Unit, Error]`，退出保护后必经取消检查，
再返回回调值或抛出收尾错误。因此正常收尾期间收到的取消优先于收尾成功或失败。
`on_return` 失败不会再调用 `on_unwind`；各适配器负责自己的失败恢复，只释放一次。
此 helper 不新增任务组或清理预算，也不把取消转换成普通 Error。

输出流作用域在有时限的清理中调用客户端内部 `finish_scope`，再在清理边界之外
抛出其返回的查询 SQL 错误。同步或资源清理实际失败才淘汰连接，回调异常仍优先。
prepared 流在创建和收尾阶段处理 26000/0A000 缓存失效，即使回调异常遮蔽了
SQL 错误也会失效；不重试执行。prepared 和流句柄在释放开始前失效，清理继续遵守
原有的连接锁、句柄锁和缓存租约规则。

Deadline 使用 `@async.now()` 的毫秒计时基准，子范围只能缩短。等待 executor
和容量共用 wait 预算；所有 host 共用 create 预算。健康检查失败允许换连接，
hook 失败则立即结束获取。最终建连错误保存各目标、阶段、耗时和原始错误。

`supervise` 为整个操作或资源作用域安装一个 RequestControl；私有
`supervise_worker` 启动工作任务，在受保护 I/O 之外的独立等待者上应用 deadline。
流方法复用作用域已有的控制和连接锁，只保留自身的互斥锁，直到工作任务退出。
因此方法级 deadline 遇到受保护的临时语句 Close 时，也受共享清理预算约束。
底层为每个请求记录编号、可能发送、命令标签和
协议完成状态；唯一读取任务在转发队列前记录标签，因此断连不能抹去已确认提交。
取消后禁止后续业务请求，Close 等清理请求必须等 CancelRequest 连接关闭后才能发送。
监督器等待取消连接和原协议清理都结束后才释放锁。取消发送失败、超时或状态不可信
时 abort。COPY IN 必须等待取消 send/finish 后移交给 executor 的 drain。
嵌套监督器先取消工作任务，再通过 `cancel_active` 加入取消流程并等待协议清理。
只有取消流程的所有者发送取消包并释放栅栏，其他监督器只能等待。
预算耗尽时 abort，仍须等待工作任务退出后才释放连接锁或流锁。
stream/COPY 回调运行在受监督的工作任务中。回调抛出普通异常时，先发布原异常，
再开始作用域收尾；等待者开始解栈时保存这个异常，完成清理和取消栅栏后保留它。
若异常在等待者已开始取消之后才出现（例如流方法稍后完成超时解栈），不能覆盖取消。
正常返回后的收尾错误和原生取消不进入这条错误传递路径。

一次异常解栈共用 `cleanup_deadline`，drain、嵌套 rollback、reset、初始化 hook
不能各自领取新的宽限期。watchdog 在 raw I/O 的取消保护之外执行 abort。
重置 hook 使用 cleanup_mode，不能通过嵌套查询重置预算。调用者已处理错误后，
下一次真正接受的业务操作可以开始新的清理周期。
子回调作用域只能在 `with_scope_exit` 正常返回后重置已结束的清理周期；失败或取消
解栈保留同一个预算，即使子作用域的清理本身成功也不能重置。

事务回调以 Ok/Err 表达提交或回滚意图，完成由 helper 管理。单次使用的
TransactionRecord 独立于事件队列。COMMIT 发送前取消则回滚；可能发送后只等待
真实结果，不追加 ROLLBACK。COMMIT、ROLLBACK、RELEASE 分别记录提交、回滚和
保存点释放。响应缺失记录未知并淘汰连接；已收到 COMMIT 标签后断连仍保留已提交。

COMMIT/RELEASE 和 rollback helper 先完成协议操作、诊断和独立的事务记录，
再由 `with_scope_exit` 决定调用方如何退出。正常收尾适配器还负责提交前失败的条件
回滚：只有已开始、仍为 InProgress 且没有活动子任务的事务才允许回滚。COMMIT
可能发送后必须先确定完成记录再抛错，因此此恢复不能在未知结果后追加 ROLLBACK。
业务 Err 属于正常返回，并请求回滚；没有取消时即使回滚失败也保留业务 Err，
收尾期间到达的取消则必须在调用方继续执行前传播。回滚成功记录 RolledBack，失败
记录 OutcomeUnknown；取消及之后的 Session 归还失败不能改写已确认的完成记录。

事务或保存点退出时，必须在完成 SQL 前同步检查自身 `active_ops`。仍有活动子任务
属于作用域使用错误：设置 releasing，保留 `OperationInProgress` 诊断并立即 abort，
整个检查不能暂停。仅将 InProgress 记录改为 OutcomeUnknown 并通知完成；异常清理和
最终 defer 再次检查时不能重复通知或覆盖已确认结果。回调返回 Ok 时抛出
OperationInProgress；业务 Err、异常、取消及 deadline 错误保持原结果。关闭连接没有
显式回滚确认，因此不能记录已回滚，也不能发送 COMMIT、RELEASE 或继续回滚。
外层回滚保留未知状态及原诊断，迟到清理不能用连接关闭或句柄过期错误覆盖淘汰原因。
先使子作用域失效，再释放父锁，容量仍只由最外层 Session 归还一次。不等待外层任务组
中的应用任务；旧 ConnectionState 永远不能重新绑定新客户端，旧任务后续操作失败且
清理不能影响新借用者。正常结束所有子任务的调用保持原有提交和复用行为。
已关闭连接的淘汰不再排队执行 graceful close：abort 已负责关闭传输，逃逸的
stream/COPY 可能仍持有底层 permit，等待该 permit 会阻塞关闭任务和连接池退出。

归还顺序：协议同步 → 清理遗留事务 → 单独执行 DISCARD ALL → 清空 statement/type
cache → initialize_session → 空闲队列。PreserveSession 保留状态但仍同步协议和回滚；
Reconnect 直接淘汰。归还清理失败以 PoolEvent 保留原始原因，不覆盖业务结果。
`with_session` 将正常退出和异常解栈交给 `with_scope_exit`，每条路径只调用一次
`Session::release`。回调正常完成后，在 reset 或初始化 hook 期间收到的取消，
会在调用方继续执行前传播，Pool 便捷方法和事务入口也遵守此规则。已有回调异常
保持优先级，已确认的事务记录保持原状态。
事件缓冲区溢出丢弃最旧条目并计数，不能影响事务完成记录。

确定性协议测试见 request_control_wbtest.mbt；受保护 Close 和方法 deadline
回归测试见 stream_deadline_wbtest.mbt，立即到期的回收预算及容量计数测试见
recycle_cancel_wbtest.mbt。transaction_scope_wbtest.mbt 覆盖各事务入口和退出原因下
逃逸 prepared 回调及阻塞 SQL、缓存和重置策略、诊断、父锁、容量及正常复用。
真实数据库状态隔离、事务意图、stream/COPY 取消及逃逸 prepared/COPY 回调对新
借用者阻塞查询的隔离测试见 tests/baseline/pgpool_redesign_integration_test.mbt。
stream_error_wbtest.mbt 区分 SQL、同步和 Close 失败；prepared_cancel_wbtest.mbt
覆盖释放期间取消。tests/baseline/pgpool_stream_error_integration_test.mbt 验证
真实 PostgreSQL 后端复用、保存点回滚和 prepared 缓存失效。
release_cancel_wbtest.mbt 覆盖 reset 和初始化期间的归还取消、回调异常优先级、
容量恢复、连接复用，以及各 Pool 入口下已确认的事务完成记录。
transaction_cancel_wbtest.mbt 覆盖 Session 事务、命名保存点和嵌套事务在回滚成功或
超时期间收到取消时的调用方后续代码、错误优先级、完成记录、连接复用及容量归还。
transaction_completion_wbtest.mbt 覆盖有无取消时 COMMIT/RELEASE 的成功、SQL 错误、
断连、超时，以及命令标签已收到但 ReadyForQuery 丢失的情况。取消 COMMIT 后清理
超时的回归测试同时断言 catch 和后续业务代码均未执行。
scope_exit_wbtest.mbt 验证回调前后的取消检查及只执行一次的收尾。
stream_cancel_wbtest.mbt 覆盖所有流和 COPY 入口的退出优先级矩阵，以及监督器
保留更早回调异常的行为。
