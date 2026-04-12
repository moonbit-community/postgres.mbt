///|
/// This type intentionally claims it only accepts `text`.
/// The test later passes it to an `int4` parameter to verify write-side type checking.
struct TextOnlyParam {
  value : String
} derive(Debug, Eq)

///|
impl @client.ToSql for TextOnlyParam with format(_, _) {
  @client.WireFormat::Text
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
/// This encoder should never run.
/// If the test reaches encoding, the earlier type check failed to stop the bad parameter.
impl @client.ToSql for TextOnlyParam with to_sql(_, _, _) {
  fail("unexpected encode")
}

///|
/// This covers WrongType errors on both the read path and the write path.
/// The first half decodes an `int4` value as `Int64`, and the second half sends a `text`-only parameter to an `int4` placeholder.
async test "integration wrong type errors on read and write" {
  guard integration_config() is Some(config) else { return }
  @async.with_task_group(group => {
    let (client, connection) = @client.connect(
      as_client_config(config, application_name="moonbit-postgres"),
    )
    group.spawn_bg(() => connection.run())

    // The query itself succeeds. The failure happens when decoding into an incompatible target type.
    let read_result : Result[Int64, Error] = try? client
      .query_one("select 1::int4 as value")
      .get_name("value")
    let read_err = expect_wrong_type_error(read_result)
    @debug.assert_eq(read_err.moonbit_type, "Int64")
    @debug.assert_eq(read_err.postgres_type, @client.Type::int4())

    // The write path should fail before encoding, so `to_sql` must never be reached.
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
