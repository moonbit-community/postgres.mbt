///|
/// An absolute instant in the async runtime's millisecond time base.
struct Deadline {
  at : Int64
}

///|
/// Construct a business deadline; zero expires immediately.
pub fn Deadline::after_ms(milliseconds : Int32) -> Deadline raise {
  if milliseconds < 0 {
    raise PoolError::InvalidConfig("deadline must be non-negative")
  }
  { at: @async.now() + milliseconds.to_int64(), }
}

///|
fn earlier_deadline(parent : Deadline?, child : Deadline?) -> Deadline? {
  match (parent, child) {
    (Some(a), Some(b)) => Some(if a.at <= b.at { a } else { b })
    (Some(a), None) | (None, Some(a)) => Some(a)
    (None, None) => None
  }
}

///|
fn remaining_ms(deadline : Deadline?, phase : TimeoutKind) -> Int32? raise {
  deadline.map(deadline => {
    let left = deadline.at - @async.now()
    if left <= 0L {
      raise PoolError::Timeout(phase)
    }
    if left > 2147483647L {
      2147483647
    } else {
      left.to_int()
    }
  })
}

///|
async fn[T] with_deadline(
  deadline : Deadline?,
  phase : TimeoutKind,
  f : async () -> T,
) -> T {
  match remaining_ms(deadline, phase) {
    None => f()
    Some(ms) => @async.with_timeout(ms, f, error=PoolError::Timeout(phase))
  }
}

///|
fn phase_deadline(deadline : Deadline?, milliseconds : Int32?) -> Deadline? {
  earlier_deadline(
    deadline,
    milliseconds.map(ms => { at: @async.now() + ms.to_int64(), }),
  )
}
