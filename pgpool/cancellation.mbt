///|
/// A nested client operation may finish while cancellation is protected by the
/// pool. Recheck outside the outer protection before returning or committing.
async fn check_pending_cancellation() -> Unit noraise {
  if @async.is_being_cancelled() {
    @async.pause()
  }
}

///|
/// Finish resources before deciding how the caller exits. Only callback unwind
/// runs on_unwind; a failed on_return must finish its own recovery, exactly once.
/// Cancellation stays runtime control flow, outside the ordinary cleanup result.
async fn[T] with_scope_exit(
  body : async () -> T,
  on_return : async (T) -> Unit,
  on_unwind : async () -> Unit,
) -> T {
  let value = {
    errdefer @async.protect_from_cancel(() => on_unwind() catch { _ => () })
    check_pending_cancellation()
    let value = body()
    check_pending_cancellation()
    value
  }
  let outcome : Result[Unit, Error] = @async.protect_from_cancel(() => {
    try on_return(value) catch {
      error => Err(error)
    } noraise {
      _ => Ok(())
    }
  })
  // Even a cleanup error must pass this check. Callback exceptions already
  // left through the local errdefer and retain their original exit reason.
  check_pending_cancellation()
  match outcome {
    Ok(_) => value
    Err(error) => raise error
  }
}
