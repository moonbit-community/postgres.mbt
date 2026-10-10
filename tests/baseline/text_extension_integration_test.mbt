///|
// Keep extension creation and all three type checks in one serial test.
async test "integration ltree extension string scalars views and arrays roundtrip" {
  guard integration_config() is Some(config) else { return }
  @async.with_task_group(group => {
    let client = start_client(
      as_client_config(config, application_name="moonbit-text-extensions"),
      group,
    )
    defer @async.protect_from_cancel(() => client.close())
    client.batch_execute("CREATE EXTENSION IF NOT EXISTS ltree")
    let cases = [
      ("ltree", "a.b", "c.d"),
      ("lquery", "a.*", "*.b"),
      ("ltxtquery", "foo", "bar"),
    ]
    for case in cases {
      let (name, first, second) = case
      let row = client.query_one("select '\{first}'::\{name}")
      assert_eq(row.columns()[0].type_.name, name)
      assert_eq(row.columns()[0].format, @client.WireFormat::Binary)
      let read : String = row.get(0)
      assert_eq(read, first)
      let roundtrip : String = client
        .query_one("select $1::\{name}", params=[first as &@client.ToSql])
        .get(0)
      assert_eq(roundtrip, first)
      let text_result : String = client
        .query_one("select ($1::\{name})::text", params=[
          first as &@client.ToSql,
        ])
        .get(0)
      assert_eq(text_result, first)
      let source = "prefix-\{first}-suffix"
      let view = source.exact_view(start=7, end=7 + first.length())
      let view_roundtrip : String = client
        .query_one("select $1::\{name}", params=[view as &@client.ToSql])
        .get(0)
      assert_eq(view_roundtrip, first)
      let null : String? = None
      let null_roundtrip : String? = client
        .query_one("select $1::\{name}", params=[null as &@client.ToSql])
        .get(0)
      assert_eq(null_roundtrip, None)

      let values : Array[String?] = [Some(first), None, Some(second)]
      let array_read : Array[String?] = client
        .query_one(
          "select array['\{first}'::\{name}, null, '\{second}'::\{name}]",
        )
        .get(0)
      assert_eq(array_read, values)
      let array_roundtrip : Array[String?] = client
        .query_one("select $1::\{name}[]", params=[values as &@client.ToSql])
        .get(0)
      assert_eq(array_roundtrip, values)
      let plain = [first, second]
      let plain_roundtrip : Array[String] = client
        .query_one("select $1::\{name}[]", params=[plain as &@client.ToSql])
        .get(0)
      assert_eq(plain_roundtrip, plain)
      let empty : Array[String] = []
      let empty_roundtrip : Array[String] = client
        .query_one("select $1::\{name}[]", params=[empty as &@client.ToSql])
        .get(0)
      assert_eq(empty_roundtrip, empty)
      let empty_read : Array[String] = client
        .query_one("select array[]::\{name}[]")
        .get(0)
      assert_eq(empty_read, empty)
      let all_null : Array[String?] = [None]
      let all_null_roundtrip : Array[String?] = client
        .query_one("select $1::\{name}[]", params=[all_null as &@client.ToSql])
        .get(0)
      assert_eq(all_null_roundtrip, all_null)
    }
  })
}
