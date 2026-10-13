// Request observations are written by the socket driver, independently of the
// task consuming responses. A command tag survives loss of ReadyForQuery.

///|
struct RequestControl {
  cancelled : @ref.Ref[Bool]
  fence : Completion
  last : @ref.Ref[RequestRecord?]
}

///|
priv struct RequestRecord {
  id : Int64
  control : RequestFence?
  cleanup : Bool
  sent : @ref.Ref[Bool]
  complete : @ref.Ref[Bool]
  tags : Array[String]
}

///|
// Requests retain the cancellation fence without retaining their controller.
// The controller owns its last record, so a back-reference would form a cycle.
priv struct RequestFence {
  cancelled : @ref.Ref[Bool]
  fence : Completion
}

///|
#internal(internal, "for use by pgpool only")
#doc(hidden)
pub fn Client::begin_request_control(self : Client) -> RequestControl raise {
  if self.shared.request_control.val is Some(_) {
    raise ClientError::Protocol("request control already installed")
  }
  let control = {
    cancelled: Ref(false),
    fence: Completion::new(),
    last: Ref(None),
  }
  self.shared.request_control.val = Some(control)
  control
}

///|
#internal(internal, "for use by pgpool only")
#doc(hidden)
pub fn Client::end_request_control(self : Client) -> Unit {
  self.shared.request_control.val = None
}

///|
/// Stop subsequent business requests. The caller must complete the cancel
/// connection before releasing the fence, even if the original request ends.
#internal(internal, "for use by pgpool only")
#doc(hidden)
pub fn RequestControl::cancel(self : RequestControl) -> Bool {
  self.cancelled.val = true
  match self.last.val {
    Some(record) => record.sent.val && !record.complete.val
    None => false
  }
}

///|
#internal(internal, "for use by pgpool only")
#doc(hidden)
pub fn RequestControl::finish_cancel(self : RequestControl) -> Unit {
  self.fence.complete(None)
}

///|
#internal(internal, "for use by pgpool only")
#doc(hidden)
pub fn RequestControl::request_id(self : RequestControl) -> Int64? {
  self.last.val.map(record => record.id)
}

///|
#internal(internal, "for use by pgpool only")
#doc(hidden)
pub fn RequestControl::was_sent(self : RequestControl) -> Bool {
  self.last.val is Some({ sent: { val: true, }, .. })
}

///|
#internal(internal, "for use by pgpool only")
#doc(hidden)
pub fn RequestControl::command_tags(self : RequestControl) -> ArrayView[String] {
  match self.last.val {
    Some(record) => record.tags[:]
    None => []
  }
}

///|
#internal(internal, "for use by pgpool only")
#doc(hidden)
pub fn RequestControl::protocol_complete(self : RequestControl) -> Bool {
  self.last.val is Some({ complete: { val: true, }, .. })
}

///|
fn Client::new_request_record(
  self : Client,
  cleanup : Bool,
) -> RequestRecord raise {
  let control = self.shared.request_control.val
  if control is Some(control) && control.cancelled.val && !cleanup {
    raise ClientError::RequestCancelled
  }
  self.shared.next_request_id.val += 1L
  let record = {
    id: self.shared.next_request_id.val,
    control: control.map(control => {
      cancelled: control.cancelled,
      fence: control.fence,
    }),
    cleanup,
    sent: Ref(false),
    complete: Ref(false),
    tags: [],
  }
  if control is Some(control) {
    control.last.val = Some(record)
  }
  record
}

///|
#internal(internal, "for use by pgpool only")
#doc(hidden)
pub fn RequestControl::is_cancelled(self : RequestControl) -> Bool {
  self.cancelled.val
}

///|
#internal(internal, "for use by pgpool only")
#doc(hidden)
pub async fn RequestControl::wait_cancel(self : RequestControl) -> Unit {
  self.fence.wait()
}
