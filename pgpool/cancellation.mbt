///|
/// A nested client operation may finish while cancellation is protected by the
/// pool. Recheck outside the outer protection before returning or committing.
async fn check_pending_cancellation() -> Unit noraise {
  if @async.is_being_cancelled() {
    @async.pause()
  }
}
