///|
struct TextOnlyParam {
  value : String
} derive(Debug, Eq)

///|
impl @client.ToSql for TextOnlyParam with format(_, _) {
  0
}

///|
impl @client.ToSql for TextOnlyParam with accepts(_, type_) {
  type_.oid == 25U
}

///|
impl @client.ToSql for TextOnlyParam with moonbit_type_name(_) {
  "TextOnlyParam"
}

///|
impl @client.ToSql for TextOnlyParam with to_sql(_, _, _) {
  fail("unexpected encode")
}

///|
async test "integration wrong type errors on read and write" {
  guard integration_config() is Some(config) else { return }
  @async.with_task_group(group => {
    let (client, connection) = @client.connect(as_client_config(config))
    group.spawn_bg(() => connection.run())

    let read_result : Result[Int64, Error] = try? client
      .query_one("select 1::int4 as value")
      .get_name("value")
    let read_err = expect_wrong_type_error(read_result)
    @debug.assert_eq(read_err.moonbit_type, "Int64")
    @debug.assert_eq(read_err.postgres_type, @client.Type::int4())

    let text_param : TextOnlyParam = { value: "moonbit" }
    let params : Array[&@client.ToSql] = [text_param as &@client.ToSql]
    let write_result : Result[Array[@client.Row], Error] = try? client
      .query_typed("select $1::int4 as value", [@client.Type::int4()], params~)
      .collect()
    let write_err = expect_wrong_type_error(write_result)
    @debug.assert_eq(write_err.moonbit_type, "TextOnlyParam")
    @debug.assert_eq(write_err.postgres_type, @client.Type::int4())

    client.close()
  })
}
