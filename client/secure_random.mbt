///|
#cfg(target="native")
#borrow(buf)
extern "C" fn secure_random_bytes_ffi(buf : FixedArray[Byte], num : Int) -> Int = "moonbit_postgres_client_secure_random_bytes"

///|
#cfg(target="native")
fn secure_random_bytes(num : Int) -> Bytes raise {
  let result = FixedArray::make(num, b'\x00')
  if secure_random_bytes_ffi(result, num) != 0 {
    raise Failure::Failure("failed to generate secure random bytes")
  }
  result.unsafe_reinterpret_as_bytes()
}

///|
#cfg(not(target="native"))
fn secure_random_bytes(_num : Int) -> Bytes raise {
  raise Failure::Failure(
    "secure random bytes are only available on native target",
  )
}
