///|
fn idle_notification_packet(
  channel : String,
  payload : String,
) -> Bytes raise @proto.ProtocolError {
  let body = Buffer()
  body.write_int_be(123)
  body.write_bytes(@proto.utf8_encode(channel))
  body.write_byte(0)
  body.write_bytes(@proto.utf8_encode(payload))
  body.write_byte(0)
  connect_backend_packet(@backend.NOTIFICATION_RESPONSE_TAG, body)
}

///|
async test "idle connection delivers notifications without another request" {
  @async.with_task_group(group => {
    let (client, connection, backend) = connection_test_pair(group)
    defer backend.close()
    let driver = group.spawn(no_wait=true, allow_failure=true, () => {
      connection.run(group)
    })
    client.shared.driver_task.val = Some(driver)
    defer client.abort()
    @async.with_timeout(2000, () => {
      backend.write(idle_notification_packet("moon_idle", "first"))
      assert_true(
        client.next_message()
        is Some(Notification({ channel: "moon_idle", payload: "first", .. })),
      )
      let ping = group.spawn(() => client.check_connection())
      assert_eq(backend.read_exactly(5), sync_bytes())
      backend.write(ready_for_query_packet(b'I'))
      ping.wait()
    })
  })
}

///|
async test "partial idle notification stays aligned when a request arrives" {
  @async.with_task_group(group => {
    let (client, connection, backend) = connection_test_pair(group)
    defer backend.close()
    let driver = group.spawn(no_wait=true, allow_failure=true, () => {
      connection.run(group)
    })
    client.shared.driver_task.val = Some(driver)
    defer client.abort()
    @async.with_timeout(2000, () => {
      let notification = idle_notification_packet("moon_partial", "second")
      backend.write(notification[:3].to_owned())
      let ping = group.spawn(() => client.check_connection())
      assert_eq(backend.read_exactly(5), sync_bytes())
      backend.write(notification[3:].to_owned())
      backend.write(ready_for_query_packet(b'I'))
      assert_true(
        client.next_message()
        is Some(
          Notification({ channel: "moon_partial", payload: "second", .. })
        ),
      )
      ping.wait()
    })
  })
}

///|
async test "idle socket EOF closes the driver without another request" {
  @async.with_task_group(group => {
    let (client, connection, backend) = connection_test_pair(group)
    let driver = group.spawn(no_wait=true, allow_failure=true, () => {
      connection.run(group)
    })
    @async.with_timeout(2000, () => {
      backend.close()
      driver.wait()
      assert_true(client.is_closed())
      assert_true(client.shared.runtime_error.val is Some(_))
      assert_true(client.next_message() is None)
    })
  })
}
