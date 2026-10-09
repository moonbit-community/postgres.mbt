// Connection identities are independent of wire resource names. Allocation is
// synchronous: it cannot interleave with another task on the async runtime.

///|
priv struct IdentityCounter {
  value : @ref.Ref[UInt64]
}

///|
let connection_ids : IdentityCounter = { value: @ref.new(0), }

///|
fn IdentityCounter::allocate(self : IdentityCounter) -> UInt64 {
  if self.value.val == 0xffffffffffffffff {
    abort("runtime identity counter exhausted")
  }
  self.value.val += 1
  self.value.val
}

///|
fn Client::assert_statement_connection(
  self : Client,
  statement : Statement,
) -> Unit raise {
  if self.shared.connection_id != statement.client.shared.connection_id {
    raise ClientError::StatementConnectionMismatch
  }
}
