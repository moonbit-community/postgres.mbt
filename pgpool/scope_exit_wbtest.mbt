///|
async test "scope exit finalizes once before propagating cancellation or cleanup failure" {
  for cancel in [false, true] {
    for cleanup_fails in [false, true] {
      @async.with_task_group(group => {
        let entered : @async.Queue[Unit] = Queue(kind=Unbounded)
        let release : @async.Queue[Unit] = Queue(kind=Unbounded)
        let returns = Ref(0)
        let unwinds = Ref(0)
        let finished = Ref(false)
        let task = group.spawn(allow_failure=true, () => {
          with_scope_exit(
            () => 7,
            value => {
              assert_eq(value, 7)
              returns.val += 1
              entered.put(())
              release.get()
              finished.val = true
              if cleanup_fails {
                raise PoolError::InvalidConfig("cleanup failed")
              }
            },
            () => unwinds.val += 1,
          )
        })
        entered.get()
        if cancel {
          task.cancel()
        }
        release.put(())
        if cancel {
          assert_true(
            expect_pgpool_error_async(() => task.wait())
            is @async.WaitedTaskAlreadyCancelled,
          )
        } else if cleanup_fails {
          assert_true(
            expect_pgpool_error_async(() => task.wait())
            is PoolError::InvalidConfig("cleanup failed"),
          )
        } else {
          assert_eq(task.wait(), 7)
        }
        assert_true(finished.val)
        assert_eq(returns.val, 1)
        assert_eq(unwinds.val, 0)
      })
    }
  }
}

///|
async test "scope exit checks pending cancellation before and after the callback" {
  for before_body in [false, true] {
    @async.with_task_group(group => {
      let entered : @async.Queue[Unit] = Queue(kind=Unbounded)
      let release : @async.Queue[Unit] = Queue(kind=Unbounded)
      let body_called = Ref(false)
      let returns = Ref(0)
      let unwinds = Ref(0)
      let hold = () => {
        @async.protect_from_cancel(() => {
          entered.put(())
          release.get()
        })
      }
      let task = group.spawn(allow_failure=true, () => {
        if before_body {
          hold()
        }
        with_scope_exit(
          () => {
            body_called.val = true
            if !before_body {
              hold()
            }
          },
          _ => returns.val += 1,
          () => {
            unwinds.val += 1
            @async.pause()
            raise PoolError::InvalidConfig("unwind failed")
          },
        )
      })
      entered.get()
      task.cancel()
      release.put(())
      assert_true(
        expect_pgpool_error_async(() => task.wait())
        is @async.WaitedTaskAlreadyCancelled,
      )
      assert_eq(body_called.val, !before_body)
      assert_eq(returns.val, 0)
      assert_eq(unwinds.val, 1)
    })
  }
}
