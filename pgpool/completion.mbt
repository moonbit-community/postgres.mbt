// Reusable notification of an executor lifecycle transition.

///|
priv struct Completion {
  done : @ref.Ref[Bool]
  error : @ref.Ref[Error?]
  signal : @async.Queue[Unit]
}

///|
fn Completion::new() -> Completion {
  {
    done: @ref.new(false),
    error: @ref.new(None),
    signal: Queue(kind=Unbounded),
  }
}

///|
fn Completion::complete(self : Completion, error : Error?) -> Unit {
  if self.done.val {
    return
  }
  self.error.val = error
  self.done.val = true
  self.signal.close()
}

///|
async fn Completion::wait(self : Completion) -> Unit {
  if !self.done.val {
    ignore(self.signal.get()) catch {
      _ => ()
    }
  }
  match self.error.val {
    Some(error) => raise error
    None => ()
  }
}
