///|
struct IntegrationNulTextParam(Bytes)

///|
impl @client.ToSql for IntegrationNulTextParam with fn accepts(_, type_) {
  type_ == @client.Type::text()
}

///|
impl @client.ToSql for IntegrationNulTextParam with fn moonbit_type_name(_) {
  "IntegrationNulTextParam"
}

///|
impl @client.ToSql for IntegrationNulTextParam with fn format(_, _) {
  Text
}

///|
impl @client.ToSql for IntegrationNulTextParam with fn to_sql(self, _, buf) {
  buf.write_bytes(self.0)
  No
}

///|
async test "integration NUL encoding errors do not execute or abort the transaction" {
  guard integration_config() is Some(config) else { return }
  @async.with_task_group(group => {
    let client = start_client(
      as_client_config(config, application_name="moonbit-nul-parameters"),
      group,
    )
    defer client.abort()
    @async.with_timeout(10000, () => {
      let prepared_before = scoped_prepared_count(client)
      client.with_transaction(tx => {
        tx.batch_execute("create temp table nul_parameter_values(value text)")
        for typed in [false, true] {
          let params : Array[&@client.ToSql] = [
            "before\u0000after",
            IntegrationNulTextParam(b"before\x00after"),
          ]
          for index, param in params {
            let error = expect_error_async(() => {
              if typed {
                tx.with_prepared_typed(
                  "insert into nul_parameter_values values ($1)",
                  [@client.Type::text()],
                  statement => statement.execute(params=[param]),
                )
              } else {
                tx.execute("insert into nul_parameter_values values ($1)", params=[
                  param,
                ])
              }
            })
            guard error is @client.ClientError::Encode(message) else {
              fail("expected client encoding error")
            }
            assert_eq(
              message,
              if index == 0 {
                "PostgreSQL string parameters must not contain NUL (U+0000)"
              } else {
                "PostgreSQL text-format parameters must not contain NUL (0x00)"
              },
            )
            let count : Int = tx.with_stream(
              "select count(*)::int4 from nul_parameter_values",
              stream => stream.next().unwrap().get(0),
            )
            assert_eq(count, 0)
          }
          let array : Array[String?] = [Some("valid"), None, Some("a\u0000b")]
          assert_true(
            expect_error_async(() => {
              if typed {
                tx.with_prepared_typed(
                  "select $1::text[]",
                  [@client.Type::text_array()],
                  statement => {
                    statement.with_stream(params=[array as &@client.ToSql], stream => {
                      ignore(stream.collect())
                    })
                  },
                )
              } else {
                tx.with_stream(
                  "select $1::text[]",
                  params=[array as &@client.ToSql],
                  stream => ignore(stream.collect()),
                )
              }
            })
            is @client.ClientError::Encode(
              "PostgreSQL string parameters must not contain NUL (U+0000)"
            ),
          )
          let bytes = b"\x00a\x00b\x00"
          let roundtrip : Bytes = tx.with_stream(
            "select $1::bytea",
            params=[bytes as &@client.ToSql],
            stream => stream.next().unwrap().get(0),
          )
          assert_eq(roundtrip, bytes)
        }
        assert_eq(
          tx.execute("insert into nul_parameter_values values ($1)", params=[
            "中文🌙" as &@client.ToSql,
          ]),
          1,
        )
      })
      assert_eq(scoped_prepared_count(client), prepared_before)
      let value : String = client
        .query_one("select value from nul_parameter_values")
        .get(0)
      assert_eq(value, "中文🌙")
    })
    client.close()
  })
}
