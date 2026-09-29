///|
/// Async counterpart to `@test.expect_error` for client white-box tests.
#callsite(autofill(loc))
async fn[T, E : Error] expect_error_async(
  f : async () -> T raise E,
  loc~ : SourceLoc,
) -> E {
  try f() catch {
    error => error
  } noraise {
    _ =>
      @test.fail(
        "expected error, but program succeeded without raising anything",
        loc~,
      )
  }
}

///|
fn test_control(group : @async.TaskGroup[Unit]?) -> DrainControl {
  let control = DrainControl::new()
  if group is Some(group) {
    group.spawn_bg(no_wait=true, () => run_control_queue(control, group))
  } else {
    control.close()
  }
  control
}
