///|
async test "request cancellation after preparation forbids execution but permits statement cleanup" {
  with_cancellation_test_client((group, client, next_request) => {
    let control = client.begin_request_control()
    let task = group.spawn(allow_failure=true, () => {
      client.query("select value").collect()
    })
    let prepare = next_request()
    prepare.record.sent.val = true
    assert_true(control.cancel())
    control.finish_cancel()
    scoped_test_prepare(prepare)
    // An Execute must never follow the now-completed preparation.
    let close = next_request()
    assert_eq(close.bytes[0], b'C')
    scoped_test_close(close)
    assert_true(
      expect_error_async(() => task.wait()) is ClientError::RequestCancelled,
    )
    assert_true(client.shared.requests.try_get() is None)
    client.end_request_control()
  })
}
