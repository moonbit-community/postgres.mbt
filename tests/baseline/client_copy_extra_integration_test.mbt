///|
/// This verifies that a COPY IN startup failure surfaces PostgreSQL's database error and still drains to a reusable connection.
/// The missing table forces PostgreSQL to reply with `ErrorResponse` before COPY mode starts.
async test "integration copy in startup error keeps connection reusable" {
  guard integration_config() is Some(config) else { return }
  @async.with_task_group(group => {
    let (client, connection) = @client.connect(
      as_client_config(config, application_name="moonbit-postgres"),
    )
    group.spawn_bg(() => connection.run())

    let err = expect_database_error(
      try? client.copy_in("copy moon_missing_copy_input from stdin"),
    )
    @debug.assert_eq(err.code, Some("42P01"))

    let probe : Int = client
      .query_one("select 17::int4 as value")
      .get_name("value")
    @debug.assert_eq(probe, 17)

    client.close()
  })
}

///|
/// This verifies that `finish()` closes the COPY IN sink for further writes or finishes after the server accepted the rows.
/// The test also checks that the inserted rows are visible immediately on the same connection.
async test "integration copy in finish closes sink and commits rows" {
  guard integration_config() is Some(config) else { return }
  @async.with_task_group(group => {
    let (client, connection) = @client.connect(
      as_client_config(config, application_name="moonbit-postgres"),
    )
    group.spawn_bg(() => connection.run())

    client.batch_execute("create temp table moon_copy_finish(value int4)")

    let sink = client.copy_in("copy moon_copy_finish from stdin")
    sink.send(b"1\n2\n"[:])
    @debug.assert_eq(sink.finish(), 2)

    let send_closed = expect_closed_error(try? sink.send(b"3\n"[:]))
    @debug.assert_eq(send_closed, "copy sink already finished")
    let finish_closed = expect_closed_error(try? sink.finish())
    @debug.assert_eq(finish_closed, "copy sink already finished")

    let count : Int = client
      .query_one("select count(*)::int4 as value from moon_copy_finish")
      .get_name("value")
    @debug.assert_eq(count, 2)

    client.close()
  })
}

///|
/// This verifies that `CopyOutStream::collect()` drains the full COPY OUT response and leaves the connection reusable.
/// The collected payloads are compared byte-for-byte because the driver exposes raw COPY chunks.
async test "integration copy out collect keeps connection reusable" {
  guard integration_config() is Some(config) else { return }
  @async.with_task_group(group => {
    let (client, connection) = @client.connect(
      as_client_config(config, application_name="moonbit-postgres"),
    )
    group.spawn_bg(() => connection.run())

    let stream = client.copy_out(
      "copy (select value from (values ('alpha'), ('beta')) as t(value) order by value) to stdout",
    )
    assert_true(stream.collect() == [b"alpha\n", b"beta\n"])

    let probe : Int = client
      .query_one("select 23::int4 as value")
      .get_name("value")
    @debug.assert_eq(probe, 23)

    client.close()
  })
}

///|
/// This verifies that `CopyOutStream::finish()` can synchronously drain a large multi-chunk response and still leave the connection reusable.
/// The payload is intentionally large so `finish()` has to iterate through remaining `CopyData` chunks instead of stopping immediately.
async test "integration copy out finish drains large payload and keeps connection reusable" {
  guard integration_config() is Some(config) else { return }
  @async.with_task_group(group => {
    let (client, connection) = @client.connect(
      as_client_config(config, application_name="moonbit-postgres"),
    )
    group.spawn_bg(() => connection.run())

    let stream = client.copy_out(
      "copy (select repeat('x', 32768) from generate_series(1, 8)) to stdout",
    )
    assert_true(stream.formats == [@client.WireFormat::Text])
    stream.finish()

    let probe : Int = client
      .query_one("select 29::int4 as value")
      .get_name("value")
    @debug.assert_eq(probe, 29)

    client.close()
  })
}
