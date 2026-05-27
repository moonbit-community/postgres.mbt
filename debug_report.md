# 调试报告：内置编解码器拒绝 Domain 类型参数

## 摘要

客户端在发送 `Bind` 消息之前就拒绝了合法的 PostgreSQL domain 值。对于推断出的 PostgreSQL 类型是某个受支持基础类型的 domain 的参数，例如基于 `text` 的 domain，客户端应当可以使用该基础类型对应的内置编解码器进行编码。但现在客户端会报告 `ClientError.WrongType`。

这是一个明确的缺陷，因为失败是确定性的，发生在任何服务端 SQL 执行之前，并且会阻塞合法的 PostgreSQL 用法。

## 最小复现

在 `tests/baseline/` 下临时添加如下集成测试，例如保存为 `tests/baseline/domain_repro_tmp_integration_test.mbt`：

```mbt
///|
async test "integration domain text parameter should accept base string codec" {
  guard integration_config() is Some(config) else { return }
  @async.with_task_group(group => {
    let (client, connection) = @client.connect(
      as_client_config(config, application_name="moonbit-postgres-domain-repro"),
    )
    group.spawn_bg(() => connection.run())

    client.batch_execute(
      "create domain pg_temp.moon_driver_nonempty_text as text check (value <> '')",
    )
    client.clear_type_cache()

    let value = "ok"
    let params : Array[&@client.ToSql] = [value]
    let row = client.query_one(
      "select $1::pg_temp.moon_driver_nonempty_text as value",
      params~,
    )
    let decoded : String = row.get_name("value")
    assert_eq(decoded, "ok")

    client.close()
  })
}
```

运行：

```bash
node scripts/pg_integration_test.mjs
```

实际结果：

```text
[moonbit-community/postgres] test tests/baseline/domain_repro_tmp_integration_test.mbt:2 ("integration domain text parameter should accept base string codec") failed: moonbit-community/postgres/client.ClientError.WrongType
Total tests: 119, passed: 118, failed: 1.
```

期望结果：查询应返回一行，并且 `value = "ok"`。

## 为什么这是合法的 PostgreSQL 用法

PostgreSQL 文档将 domain 描述为基于另一个底层类型定义的用户自定义数据类型，并且可以附加额外约束。除此之外，domain 的行为与其底层类型一致；把底层类型的值赋给 domain 是允许的，同时 PostgreSQL 会检查 domain 约束。

复现用例创建了如下 domain：

```sql
create domain pg_temp.moon_driver_nonempty_text as text check (value <> '');
```

参数值 `"ok"` 是合法的 `text` 值，并且满足该 domain 的约束，因此 PostgreSQL 应当可以接受它作为 `pg_temp.moon_driver_nonempty_text`。

## 根因

类型缓存已经正确识别了 domain。在 `client/type_cache.mbt` 中，catalog 查询读取 `t.typbasetype`，并把 domain 元数据保存为 `Kind::Domain(base_oid)`：

```mbt
let base_oid : @proto.Oid = row.get(4)
...
} else if base_oid != 0U {
  Domain(base_oid)
}
```

类型描述符也显式建模了 domain：

```mbt
pub enum Kind {
  ...
  Domain(@proto.Oid)
  ...
}
```

问题发生在后续的客户端编解码兼容性检查中。序列化参数之前，`encode_param` 会调用 `param.accepts(type_)`。对于 `String`，`accepts` 委托给 `is_text_type`：

```mbt
pub impl ToSql for String with fn accepts(_, type_) {
  is_text_type(type_)
}
```

`is_text_type` 只检查直接的内置文本类型 OID 和少数类型名：

```mbt
fn is_text_type(type_ : Type) -> Bool {
  match type_.oid {
    NAME_OID | TEXT_OID | VARCHAR_OID => true
    _ =>
      match type_.name {
        "bpchar" | "citext" | "lquery" | "ltree" | "ltxtquery" | "unknown" =>
          true
        _ => false
      }
  }
}
```

对于基于 `text` 的 domain，类型描述符形如：

```text
oid  = <domain oid>
name = "moon_driver_nonempty_text"
kind = Domain(25U)  // 25U is text
```

由于该谓词忽略了 `kind`，它会拒绝 domain 的 OID 和 domain 名称，即使它的基础类型是正确的。这会导致值到达 PostgreSQL 之前就产生 `ClientError.WrongType`。

同样的模式很可能也影响其他内置编解码器，而不只是 `String`。例如：

- `Int` 只接受直接的 `int2` / `int4` OID，因此会拒绝基于 `int4` 的 domain。
- `Int64`、`Float`、`Double`、`UInt`、`Bytes` 和 `Json` 都使用直接 OID 谓词，因此也会拒绝匹配的 domain。
- `FromSql for String` 也会调用 `is_text_type`，所以把 domain 类型的结果列读取为 `String` 时也存在同样的兼容性问题。

## 协议层背景

客户端流程使这个问题暴露出来：

1. `Client::query` 发送 `Parse + Describe + Sync`。
2. PostgreSQL 返回 `ParameterDescription`，其中包含每个参数类型的 OID。
3. 客户端通过 `lookup_type` 解析该 OID；domain OID 会变成 `Kind::Domain(base_oid)`。
4. 在发送 `Bind` 之前，客户端检查 `ToSql::accepts`。
5. 内置编解码器忽略 `Domain(base_oid)`，并拒绝该值。

PostgreSQL 协议文档支持这一流程：`ParameterDescription` 会报告每个参数数据类型的对象 ID；`Bind` 会用文本或二进制格式码发送参数值；`RowDescription` 会报告每个结果字段的类型 OID 和格式码。

## 建议修复方向

增加一个小的“编解码目标类型”辅助函数，在内置编解码器进行兼容性检查以及编码、解码分支判断之前，把 domain 展开为其基础类型：

```mbt
fn codec_base_type(type_ : Type) -> Type {
  match type_.kind {
    Domain(base_oid) => resolve_type(base_oid)
    _ => type_
  }
}
```

然后在 `is_text_type`、`is_bytes_type`、`is_json_type`、`array_element_type`，以及目前直接匹配 `type_.oid` 的标量 `accepts` / `to_sql` / `from_sql` 路径中一致使用该辅助函数。

修复应保留公开的行元数据和参数元数据中的原始 domain `Type`，这样调用方仍然可以观察到 PostgreSQL 推断出了 domain。只有编解码兼容性和线缆表示应当使用基础类型。Domain 约束仍应保留为服务端检查，由 PostgreSQL 在把传入值转换为 domain 时执行。

## 回归覆盖

至少应增加以下集成覆盖：

- 将 `String` 绑定到 `text` domain，并读回该值。
- 将 `text` domain 结果读取为 `String`。
- 将非法值绑定到带约束的 domain，并验证 PostgreSQL 返回数据库错误，而不是客户端侧的 `WrongType`。

有价值的后续覆盖：

- 基于 `int4`、`uuid`、`jsonb` 和内置编解码器支持的数组类型的 domain。
- 如果实现递归展开，则覆盖嵌套 domain。

## PostgreSQL 参考资料

- Domain types:
  https://www.postgresql.org/docs/current/domains.html
- `CREATE DOMAIN`:
  https://www.postgresql.org/docs/current/sql-createdomain.html
- `pg_type` catalog, including `typtype` and `typbasetype`:
  https://www.postgresql.org/docs/current/catalog-pg-type.html
- Frontend/backend protocol message formats, including `ParameterDescription`, `Bind`, and `RowDescription`:
  https://www.postgresql.org/docs/current/protocol-message-formats.html
