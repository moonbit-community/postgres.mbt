///|
async test "row stream detach does not swallow non-database drain failures" {
  let result = expect_error_async(() => {
    @async.with_task_group(group => {
      let background_group : @ref.Ref[@async.TaskGroup[Unit]?] = @ref.new(
        Some(group),
      )
      let responses : @async.Queue[@backend.Message] = Queue(kind=Unbounded)
      let stream = new_row_stream(background_group, responses)
      responses.close(error=ClientError::UnexpectedMessage("boom"), clear=true)
      stream.detach()
    })
  })
  guard result is ClientError::UnexpectedMessage(message) else {
    fail("expected detached drain to surface non-database error")
  }
  @debug.assert_eq(message, "boom")
}
