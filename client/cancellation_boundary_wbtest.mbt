///|
async test "cancellation boundary preserves results and errors" {
  assert_eq(with_cancellation_boundary(() => 42), 42)
  let error = expect_error_async(() => {
    let _ : Unit = with_cancellation_boundary(() => {
      raise ClientError::Protocol("protected operation failed")
    })
  })
  assert_true(error is ClientError::Protocol("protected operation failed"))
}

///|
async test "cancellation boundary finishes protected work before propagating cancellation" {
  @async.with_timeout(2000, () => {
    @async.with_task_group(group => {
      for fail_operation in [false, true] {
        let entered : @async.Queue[Unit] = Queue(kind=Unbounded)
        let continue_work : @async.Queue[Unit] = Queue(kind=Unbounded)
        defer continue_work.close()
        let finished = Ref(false)
        let task = group.spawn(allow_failure=true, () => {
          with_cancellation_boundary(() => {
            entered.put(())
            continue_work.get()
            finished.val = true
            if fail_operation {
              raise ClientError::Protocol("protected operation failed")
            }
          })
        })
        entered.get()
        task.cancel()
        assert_false(finished.val)
        continue_work.put(())
        let error = expect_error_async(() => task.wait())
        assert_true(error is @async.WaitedTaskAlreadyCancelled)
        assert_true(finished.val)
      }
    })
  })
}

///|
async test "cancellation boundary respects enclosing protection" {
  @async.with_timeout(2000, () => {
    @async.with_task_group(group => {
      let entered : @async.Queue[Unit] = Queue(kind=Unbounded)
      let continue_work : @async.Queue[Unit] = Queue(kind=Unbounded)
      defer continue_work.close()
      let returned = Ref(false)
      let task = group.spawn(allow_failure=true, () => {
        @async.protect_from_cancel(() => {
          let value = with_cancellation_boundary(() => {
            entered.put(())
            continue_work.get()
            42
          })
          assert_eq(value, 42)
          returned.val = true
        })
        check_pending_cancellation()
      })
      entered.get()
      task.cancel()
      continue_work.put(())
      let error = expect_error_async(() => task.wait())
      assert_true(error is @async.WaitedTaskAlreadyCancelled)
      assert_true(returned.val)
    })
  })
}
