// A one-shot result that any number of tasks may await.

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

///|
priv struct DrainControl {
  queue : @async.Queue[async () -> Unit]
  pending : Array[DrainCompletion]
  next_id : @ref.Ref[Int]
  closed : @ref.Ref[Bool]
}

///|
priv struct DrainCompletion {
  id : Int
  completion : Completion
}

///|
fn DrainControl::new() -> DrainControl {
  {
    queue: Queue(kind=Unbounded),
    pending: [],
    next_id: @ref.new(0),
    closed: @ref.new(false),
  }
}

///|
fn DrainControl::finish(
  self : DrainControl,
  id : Int,
  completion : Completion,
  error : Error?,
) -> Unit {
  completion.complete(error)
  for i in 0..<self.pending.length() {
    if self.pending[i].id == id {
      ignore(self.pending.remove(i))
      return
    }
  }
}

///|
fn DrainControl::close(
  self : DrainControl,
  error? : Error = ClientError::Closed("connection is closed"),
) -> Unit {
  if self.closed.val {
    return
  }
  self.closed.val = true
  self.queue.close(clear=true)
  while self.pending.length() > 0 {
    let item = self.pending.remove(self.pending.length() - 1)
    item.completion.complete(Some(error))
  }
}
