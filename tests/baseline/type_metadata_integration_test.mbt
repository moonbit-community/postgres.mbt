///|
/// One scalar codec suffices for Array[SchemaStatus] and its nullable elements.
priv enum SchemaStatus {
  Ready
  Done
} derive(Debug, Eq)

///|
fn schema_status_accepts(type_ : @client.Type) -> Bool {
  type_.schema == Some("moon_descriptor_a") &&
  type_.name == "status" &&
  type_.kind is Enum(_)
}

///|
impl @client.ToSql for SchemaStatus with fn accepts(_, type_) {
  schema_status_accepts(type_)
}

///|
impl @client.ToSql for SchemaStatus with fn moonbit_type_name(_) {
  "SchemaStatus"
}

///|
impl @client.ToSql for SchemaStatus with fn to_sql(self, type_, buf) {
  assert_true(schema_status_accepts(type_))
  buf.write_bytes(
    match self {
      Ready => b"ready"
      Done => b"done"
    },
  )
  @proto.IsNull::No
}

///|
impl @client.FromSql for SchemaStatus with fn accepts(type_) {
  schema_status_accepts(type_)
}

///|
impl @client.FromSql for SchemaStatus with fn moonbit_type_name() {
  "SchemaStatus"
}

///|
impl @client.FromSql for SchemaStatus with fn from_sql(type_, format, raw) {
  assert_true(schema_status_accepts(type_))
  assert_eq(format, @client.WireFormat::Binary)
  match @utf8.decode(raw) {
    "ready" => Ready
    "done" => Done
    _ => fail("invalid status")
  }
}

///|
async fn descriptor_column(
  client : @client.Client,
  sql : String,
) -> @client.Type {
  client.with_stream(sql, stream => stream.columns()[0].type_)
}

///|
async test "integration schema recursive descriptors and scalar codecs for enum arrays" {
  guard integration_config() is Some(config) else { return }
  @async.with_task_group(group => {
    let client = start_client(
      as_client_config(config, application_name="moonbit-type-descriptors"),
      group,
    )
    let drop_sql = "drop schema if exists moon_descriptor_a cascade; drop schema if exists moon_descriptor_b cascade"
    errdefer @async.protect_from_cancel(() => {
      client.batch_execute(drop_sql) catch {
        _ => ()
      }
    })
    client.batch_execute(
      (
        #|create schema moon_descriptor_a;
        #|create schema moon_descriptor_b;
        #|create type moon_descriptor_a.status as enum ('ready', 'done');
        #|create type moon_descriptor_b.status as enum ('ready', 'done');
        #|create domain moon_descriptor_a.status_domain as moon_descriptor_a.status;
        #|create type moon_descriptor_a.status_range as range (subtype = moon_descriptor_a.status);
        #|create type moon_descriptor_a.inner_pair as (
        #|  mood moon_descriptor_a.status, moods moon_descriptor_a.status[],
        #|  wrapped moon_descriptor_a.status_domain
        #|);
        #|create type moon_descriptor_a.outer_pair as (
        #|  left_pair moon_descriptor_a.inner_pair, right_pair moon_descriptor_a.inner_pair,
        #|  interval moon_descriptor_a.status_range
        #|);
      ),
    )
    client.clear_type_cache()
    let a_row = client.query_one("select 'ready'::moon_descriptor_a.status")
    let b_row = client.query_one("select 'ready'::moon_descriptor_b.status")
    let a = a_row.columns()[0].type_
    let b = b_row.columns()[0].type_
    assert_eq(a.name, b.name)
    assert_eq(a.kind, b.kind)
    assert_eq(a.schema, Some("moon_descriptor_a"))
    assert_eq(b.schema, Some("moon_descriptor_b"))
    let scalar : SchemaStatus = a_row.get(0)
    assert_eq(scalar, Ready)
    assert_true(
      @test.expect_error(() => {
        let _ : SchemaStatus = b_row.get(0)
      })
      is @client.ClientError::WrongType(_),
    )
    assert_true(
      expect_error_async(() => {
        client.query_one("select $1::moon_descriptor_b.status", params=[
          SchemaStatus::Ready as &@client.ToSql,
        ])
      })
      is @client.ClientError::WrongType(_),
    )

    let array_row = client.query_one(
      "select array['ready'::moon_descriptor_a.status, null, 'done'::moon_descriptor_a.status]",
    )
    let array_type = array_row.columns()[0].type_
    guard array_type.kind is Array(element) else {
      fail("expected array descriptor")
    }
    assert_eq(element, a)
    assert_eq(array_type.schema, a.schema)
    let values : Array[SchemaStatus?] = array_row.get(0)
    assert_eq(values, [Some(Ready), None, Some(Done)])
    let roundtrip : Array[SchemaStatus?] = client
      .query_one("select $1::moon_descriptor_a.status[]", params=[
        values as &@client.ToSql,
      ])
      .get(0)
    assert_eq(roundtrip, values)
    let typed : Array[SchemaStatus?] = client.with_typed_stream(
      "select $1",
      [array_type],
      stream => stream.one().get(0),
      params=[values as &@client.ToSql],
    )
    assert_eq(typed, values)
    let empty : Array[SchemaStatus] = []
    let empty_roundtrip : Array[SchemaStatus] = client
      .query_one("select $1::moon_descriptor_a.status[]", params=[
        empty as &@client.ToSql,
      ])
      .get(0)
    assert_true(empty_roundtrip.is_empty())
    let empty_read : Array[SchemaStatus] = client
      .query_one("select array[]::moon_descriptor_a.status[]")
      .get(0)
    assert_true(empty_read.is_empty())
    let plain : Array[SchemaStatus] = [Ready, Done]
    let plain_roundtrip : Array[SchemaStatus] = client
      .query_one("select $1::moon_descriptor_a.status[]", params=[
        plain as &@client.ToSql,
      ])
      .get(0)
    assert_eq(plain_roundtrip, plain)
    assert_true(
      expect_error_async(() => {
        client.query_one("select $1::moon_descriptor_b.status[]", params=[
          plain as &@client.ToSql,
        ])
      })
      is @client.ClientError::WrongType(_),
    )
    assert_true(
      expect_error_async(() => {
        client.query_one("select $1::moon_descriptor_a.status[]", params=[
          [1] as &@client.ToSql,
        ])
      })
      is @client.ClientError::WrongType(_),
    )
    let b_array_row = client.query_one(
      "select array['ready'::moon_descriptor_b.status]",
    )
    assert_true(
      @test.expect_error(() => {
        let _ : Array[SchemaStatus] = b_array_row.get(0)
      })
      is @client.ClientError::WrongType(_),
    )

    let domain = client.prepare("select $1::moon_descriptor_a.status_domain")
    let domain_type = domain.params()[0]
    guard domain_type.kind is Domain(base) else { fail("expected domain") }
    assert_eq(base, a)
    domain.close()
    let range_type = descriptor_column(
      client, "select null::moon_descriptor_a.status_range",
    )
    guard range_type.kind is Range(subtype) else { fail("expected range") }
    assert_eq(subtype, a)
    let outer = descriptor_column(
      client, "select null::moon_descriptor_a.outer_pair",
    )
    guard outer.kind is Composite(fields) else {
      fail("expected outer composite")
    }
    assert_eq(fields.length(), 3)
    assert_eq(fields[0].type_, fields[1].type_)
    assert_eq(fields[2].type_, range_type)
    guard fields[0].type_.kind is Composite(inner) else {
      fail("expected nested composite")
    }
    assert_eq(inner[0].type_, a)
    assert_eq(inner[1].type_, array_type)
    assert_eq(inner[2].type_, domain_type)
    assert_eq(
      descriptor_column(client, "select null::moon_descriptor_a.outer_pair"),
      outer,
    )
    client.clear_type_cache()
    assert_eq(
      descriptor_column(client, "select null::moon_descriptor_a.outer_pair"),
      outer,
    )
    let after_clear : Array[SchemaStatus?] = client
      .query_one("select $1::moon_descriptor_a.status[]", params=[
        values as &@client.ToSql,
      ])
      .get(0)
    assert_eq(after_clear, values)
    client.batch_execute(drop_sql)
    client.close()
  })
}
