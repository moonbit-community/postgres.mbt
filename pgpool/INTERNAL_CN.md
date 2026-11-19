# 连接池实现约束

`PoolExecutor` 管理物理连接的执行器以及建连和关闭任务。
每次 checkout 预留一个容量槽。交接前由 checkout 的异常清理归还，交接后由
`Session::release` 归还。淘汰连接只更新物理连接计数。连接完成重置后才加入空闲队列。
获取连接时收到取消，会淘汰当时持有的连接。空闲连接出队后先登记失败时的淘汰操作，
再检查回收期限。这样，即使期限已经过了，该连接也会关闭。

Session 和 Transaction 共用 `ClientLeaseState`。业务操作先检查作用域有效性，
再用 `Mutex::try_acquire` 立即获取连接锁，重叠调用直接失败。事务持有父 Session
的锁，保存点持有父 Transaction 的锁。子作用域过期后才释放父锁。prepared 回调计入
活动作用域，准备、执行和释放句柄时获取父锁。流和 COPY 持有连接锁直到清理结束，
句柄通过单独的锁和活动标记检查过期及重叠调用。仍在外层任务中运行的操作会导致连接淘汰。

事务、prepared、stream/COPY 和 Session 归还共用 `with_scope_exit` 退出协议。
回调保持可取消，调用前后都检查取消。局部 `errdefer` 在保护下执行 `on_unwind`，
忽略清理异常，保留原回调异常或原生取消。回调正常返回时，助手在保护下执行
`on_return`，将普通异常存入内部 `Result[Unit, Error]`，再到保护外检查取消。
收尾期间收到的取消优先于收尾结果。`on_return` 失败时由各适配器自行恢复，只释放
一次资源。`with_scope_exit` 使用调用方的任务组和清理预算，取消仍由运行时处理。

输出流作用域在有时限的清理中调用客户端内部 `finish_scope`，再在清理边界之外
抛出其返回的查询 SQL 错误。同步或资源清理实际失败才淘汰连接，回调异常仍优先。
prepared 流在创建或清理时遇到 26000/0A000 会使缓存条目失效，即使回调异常优先于
SQL 错误。是否重试由调用方决定。prepared 和流句柄在释放前失效，清理时仍获取相应的锁
并归还缓存租约。

Deadline 使用 `@async.now()` 的毫秒计时基准，子作用域继承最早到期的期限。
等待执行器和容量共用 wait 预算，所有主机共用 create 预算。健康检查失败时可以换连接。
钩子失败会结束获取。若获取抛出 `AcquireError::AttemptsFailed`，错误中会保留已记录的
各次尝试的目标、阶段、耗时和原始错误。

`supervise` 为整个操作或资源作用域安装一个 RequestControl；私有
`supervise_worker` 启动工作任务，在受保护 I/O 之外的独立等待者上应用 deadline。
流方法复用作用域已有的控制和连接锁，只保留自身的互斥锁，直到工作任务退出。
流方法超时时，受保护的临时语句 Close 也受共享清理预算约束。每个请求都有编号。
驱动器在写入前标记请求可能已发送，读取任务在转发前保存命令标签和协议完成状态，
所以断连后仍能保留已确认的提交。取消后会阻止后续业务请求，Close 等清理请求须等待
取消屏障。如果确实需要发送 CancelRequest，屏障所有者等待独立 TCP 连接读到 EOF。
监督器等待取消流程和原请求的协议清理完成，再释放锁。取消发送失败、超时或无法确认
协议同步时，关闭连接。COPY IN 的 send/finish 取消后若把排空交给执行器，清理仍会等它结束。
嵌套监督器先取消工作任务，再通过 `cancel_active` 加入取消流程并等待协议清理。
只有取消流程的所有者发送取消包并释放栅栏，其他监督器只能等待。
预算耗尽时 abort，仍须等待工作任务退出后才释放连接锁或流锁。
stream/COPY 回调运行在受监督的工作任务中。回调抛出普通异常时，先发布原异常，
再开始作用域收尾；等待者开始解栈时保存这个异常，完成清理和取消栅栏后保留它。
若异常在等待者已开始取消之后才出现（例如流方法稍后完成超时解栈），不能覆盖取消。
正常返回后的收尾错误和原生取消不进入这条错误传递路径。

异常解栈共用 `cleanup_deadline`。排空、嵌套回滚、重置和初始化都使用剩余预算。
即使底层 I/O 有取消保护，清理超时仍会关闭连接。重置钩子使用 cleanup_mode，钩子里的
查询沿用当前期限。调用方处理错误后，下一次接受的业务操作可以开始新的清理周期。
子回调作用域在 `with_scope_exit` 正常返回后才能清除已用的预算。失败或取消时，就算
子作用域已顺利清理，外层作用域仍沿用剩余预算。

事务回调返回 Ok 时提交事务或释放保存点，返回 Err、抛出异常或取消时回滚。单次使用的
TransactionRecord 独立于事件队列。取消发生在 COMMIT 发送前时回滚，可能已发送时等待
服务器结果。COMMIT、ROLLBACK 和 RELEASE 标签分别记录提交、回滚和保存点释放。
缺少能确定结果的标签时，记录未知状态并淘汰连接，且不补发 ROLLBACK。若服务器已返回
明确的数据库错误，就继续抛出该错误，否则抛出 CommitOutcomeUnknown。已收到 COMMIT
标签后，即使连接断开也保留提交记录。

COMMIT/RELEASE 和 rollback helper 先完成协议操作、诊断和独立的事务记录，
再由 `with_scope_exit` 决定调用方如何退出。正常收尾适配器还负责提交前失败的条件
回滚：只有已开始、仍为 InProgress 且没有活动子任务的事务才允许回滚。COMMIT
可能发送后必须先确定完成记录再抛错，因此此恢复不能在未知结果后追加 ROLLBACK。
业务 Err 属于正常返回，并请求回滚；没有取消时即使回滚失败也保留业务 Err，
收尾期间到达的取消则必须在调用方继续执行前传播。回滚成功记录 RolledBack，失败
记录 OutcomeUnknown；取消及之后的 Session 归还失败不能改写已确认的完成记录。

事务或保存点退出时，必须在完成 SQL 前同步检查自身 `active_ops`。仍有活动子任务
属于作用域使用错误。连接池设置 releasing，保留 `OperationInProgress` 诊断并同步关闭
连接。仅将 InProgress 记录改为 OutcomeUnknown 并通知完成。异常清理和
最终 defer 再次检查时不能重复通知或覆盖已确认结果。回调返回 Ok 时抛出
OperationInProgress。业务 Err、异常、取消及 deadline 错误保持原结果。关闭连接没有
显式回滚确认，因此不能记录已回滚，也不能发送 COMMIT、RELEASE 或继续回滚。
外层回滚保留未知状态及原诊断，迟到清理不能用连接关闭或句柄过期错误覆盖淘汰原因。
先使子作用域失效，再释放父锁，容量由最外层 Session 归还。外层任务可能在作用域退出后
继续运行，其 ConnectionState 只关联已淘汰的连接。

所有淘汰路径都负责关闭物理连接，包括健康检查成功前连接池已关闭的情况。
重复淘汰只更新一次连接计数并记录一次诊断事件。容量许可由 checkout 或 Session 归还。
淘汰已关闭的客户端时跳过 `Client::shutdown()`。调用 `Client::close()` 后由驱动器
清理传输连接。逃逸的 stream/COPY 可能仍持有底层许可，等待该许可会阻塞关闭任务和连接池退出。

在默认策略下，归还时先完成协议清理，必要时回滚遗留事务，再单独执行 DISCARD ALL。
清除语句和类型缓存、运行 initialize_session 后，连接才能进入空闲队列。
PreserveSession 完成协议和事务清理后保留会话状态。Reconnect 在必要的回滚之后关闭连接。
归还失败会通过 PoolEvent 保留原始错误，业务结果照常返回。
`with_session` 将正常退出和异常解栈交给 `with_scope_exit`，每条路径只调用一次
`Session::release`。回调正常完成后，在 reset 或初始化 hook 期间收到的取消，
会在调用方继续执行前传播，Pool 便捷方法和事务入口也遵守此规则。已有回调异常
保持优先级，已确认的事务记录保持原状态。
事件缓冲区溢出丢弃最旧条目并计数，不能影响事务完成记录。

## 测试

request_control_wbtest.mbt 包含确定性协议测试。stream_deadline_wbtest.mbt 覆盖受保护
的 Close 和方法期限，recycle_cancel_wbtest.mbt 覆盖立即到期的回收预算和容量计数。
transaction_scope_wbtest.mbt 覆盖各事务入口和退出原因下
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
