///|
fn bytes_of(bytes : ArrayView[Byte]) -> Bytes {
  Bytes::from_array(bytes)
}

///|
fn[T] assert_invalid_input(
  actual : Result[T, Error],
  expected : String,
) -> Unit raise {
  guard actual is Err(@proto.ProtocolError::InvalidInput(message)) else {
    fail("expected invalid input error")
  }
  assert_eq(message, expected)
}

///|
fn[T] assert_overflow(
  actual : Result[T, Error],
  expected : String,
) -> Unit raise {
  guard actual is Err(@proto.ProtocolError::Overflow(message)) else {
    fail("expected overflow error")
  }
  assert_eq(message, expected)
}

///|
fn collect_hstore(entries : HstoreEntries) -> Array[(Bytes, Bytes?)] raise {
  let out : Array[(Bytes, Bytes?)] = []
  for entry = entries.next() {
    match entry {
      None => break out
      Some(entry) => {
        out.push(entry)
        continue entries.next()
      }
    }
  }
}

///|
fn collect_dimensions(dims : ArrayDimensions) -> Array[ArrayDimension] raise {
  let out : Array[ArrayDimension] = []
  for dim = dims.next() {
    match dim {
      None => break out
      Some(dim) => {
        out.push(dim)
        continue dims.next()
      }
    }
  }
}

///|
fn collect_array_values(values : ArrayValues) -> Array[Bytes?] raise {
  let out : Array[Bytes?] = []
  for value = values.next() {
    match value {
      None => break out
      Some(value) => {
        out.push(value)
        continue values.next()
      }
    }
  }
}

///|
fn collect_path_points(points : PathPoints) -> Array[(Double, Double)] raise {
  let out : Array[(Double, Double)] = []
  for point = points.next() {
    match point {
      None => break out
      Some(point) => {
        out.push((point.x, point.y))
        continue points.next()
      }
    }
  }
}

///|
fn encode_array(
  dimensions : Array[ArrayDimension],
  values : Array[Bytes?],
) -> Bytes raise @proto.ProtocolError {
  let buf = @buffer.new()
  array_to_sql(
    dimensions.iter(),
    25U,
    values.iter(),
    (value, payload) => {
      match value {
        None => @proto.IsNull::Yes
        Some(value) => {
          payload.write_bytes(value)
          @proto.IsNull::No
        }
      }
    },
    buf,
  )
  buf.to_bytes()
}

///|
fn encode_range(
  lower : RangeBound[Bytes?],
  upper : RangeBound[Bytes?],
) -> Bytes raise @proto.ProtocolError {
  let buf = @buffer.new()
  range_to_sql(
    lower_buf => {
      match lower {
        Inclusive(Some(value)) => {
          lower_buf.write_bytes(value)
          Inclusive(@proto.IsNull::No)
        }
        Inclusive(None) => Inclusive(@proto.IsNull::Yes)
        Exclusive(Some(value)) => {
          lower_buf.write_bytes(value)
          Exclusive(@proto.IsNull::No)
        }
        Exclusive(None) => Exclusive(@proto.IsNull::Yes)
        Unbounded => Unbounded
      }
    },
    upper_buf => {
      match upper {
        Inclusive(Some(value)) => {
          upper_buf.write_bytes(value)
          Inclusive(@proto.IsNull::No)
        }
        Inclusive(None) => Inclusive(@proto.IsNull::Yes)
        Exclusive(Some(value)) => {
          upper_buf.write_bytes(value)
          Exclusive(@proto.IsNull::No)
        }
        Exclusive(None) => Exclusive(@proto.IsNull::Yes)
        Unbounded => Unbounded
      }
    },
    buf,
  )
  buf.to_bytes()
}

///|
fn assert_range_bound_equals(
  actual : RangeBound[Bytes?],
  expected : RangeBound[Bytes?],
) -> Unit raise {
  match (actual, expected) {
    (Inclusive(actual), Inclusive(expected)) => assert_true(actual == expected)
    (Exclusive(actual), Exclusive(expected)) => assert_true(actual == expected)
    (Unbounded, Unbounded) => ()
    _ => fail("range bound mismatch")
  }
}

///|
fn expect_nonempty_range(
  actual : Range,
  lower : RangeBound[Bytes?],
  upper : RangeBound[Bytes?],
) -> Unit raise {
  guard actual is Nonempty(actual_lower, actual_upper) else {
    fail("expected nonempty range")
  }
  assert_range_bound_equals(actual_lower, lower)
  assert_range_bound_equals(actual_upper, upper)
}

///|
test "protocol types scalar codecs handle boundaries and errors" {
  let text_buf = @buffer.new()
  text_to_sql(b"moon"[:], text_buf)
  assert_eq(text_buf.to_bytes(), b"moon")
  assert_eq(text_from_sql(b"moon"[:]), b"moon")
  assert_invalid_input(
    try? text_from_sql(bytes_of([b'\xC2'])[:]),
    "invalid UTF-8",
  )

  assert_eq(bool_from_sql(bytes_of([1])[:]), true)
  assert_eq(bool_from_sql(bytes_of([0])[:]), false)
  assert_invalid_input(try? bool_from_sql(b""[:]), "invalid buffer size")

  let char_buf = @buffer.new()
  char_to_sql(-1, char_buf)
  assert_eq(char_buf.to_bytes(), bytes_of([255]))
  assert_eq(char_from_sql(bytes_of([255])[:]), -1)
  assert_eq(char_from_sql(bytes_of([65])[:]), 65)
  assert_overflow(
    try? char_to_sql(128, @buffer.new()),
    "value out of range for i8",
  )
  assert_invalid_input(try? char_from_sql(b""[:]), "invalid buffer size")

  let mac = bytes_of([1, 2, 3, 4, 5, 6])
  let mac_buf = @buffer.new()
  macaddr_to_sql(mac[:], mac_buf)
  assert_eq(mac_buf.to_bytes(), mac)
  assert_eq(macaddr_from_sql(mac[:]), mac)
  assert_invalid_input(
    try? macaddr_to_sql(bytes_of([1, 2, 3])[:], @buffer.new()),
    "invalid MAC address length",
  )
  assert_invalid_input(
    try? macaddr_from_sql(bytes_of([1, 2, 3])[:]),
    "invalid message length: macaddr length mismatch",
  )

  let uuid = bytes_of([0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15])
  let uuid_buf = @buffer.new()
  uuid_to_sql(uuid[:], uuid_buf)
  assert_eq(uuid_buf.to_bytes(), uuid)
  assert_eq(uuid_from_sql(uuid[:]), uuid)
  assert_invalid_input(
    try? uuid_to_sql(bytes_of([1, 2, 3])[:], @buffer.new()),
    "invalid UUID length",
  )
  assert_invalid_input(
    try? uuid_from_sql(bytes_of([1, 2, 3])[:]),
    "invalid message length: uuid size mismatch",
  )
}

///|
test "protocol types hstore and varbit codecs preserve values and reject malformed payloads" {
  let hstore_buf = @buffer.new()
  hstore_to_sql([(b"a"[:], Some(b"1"[:])), (b"b"[:], None)].iter(), hstore_buf)
  let entries = collect_hstore(hstore_from_sql(hstore_buf.to_bytes()[:]))
  assert_true(entries == [(b"a", Some(b"1")), (b"b", None)])
  assert_invalid_input(
    try? hstore_from_sql(bytes_of([255, 255, 255, 255])[:]),
    "invalid entry count",
  )

  let broken_hstore = @buffer.new()
  broken_hstore.write_int_be(1)
  broken_hstore.write_int_be(-2)
  let broken_entries = hstore_from_sql(broken_hstore.to_bytes()[:])
  assert_invalid_input(try? broken_entries.next(), "invalid key length")

  let varbit_buf = @buffer.new()
  varbit_to_sql(10, [b'\xAA', b'\x80'].iter(), varbit_buf)
  let varbit = varbit_from_sql(varbit_buf.to_bytes()[:])
  assert_eq(varbit.len, 10)
  assert_eq(varbit.bytes, bytes_of([b'\xAA', b'\x80'])[:])
  assert_eq(varbit.is_empty(), false)
  let empty_varbit = varbit_from_sql(bytes_of([0, 0, 0, 0])[:])
  assert_eq(empty_varbit.is_empty(), true)
  assert_invalid_input(
    try? varbit_from_sql(bytes_of([255, 255, 255, 255])[:]),
    "invalid varbit length: varbit < 0",
  )
  assert_invalid_input(
    try? varbit_from_sql(bytes_of([0, 0, 0, 9, 1])[:]),
    "invalid message length: varbit mismatch",
  )
}

///|
test "protocol types array codecs cover round trip and iterator error paths" {
  let dimensions = [ArrayDimension::new(3, 1)]
  let values : Array[Bytes?] = [Some(b"a"), None, Some(b"xyz")]
  let encoded = encode_array(dimensions, values)
  let array = array_from_sql(encoded[:])
  assert_eq(array.dimensions, 1)
  assert_eq(array.has_nulls, true)
  assert_eq(array.element_type, 25U)
  assert_eq(array.elements, 3)
  assert_true(collect_dimensions(array.dimensions()) == dimensions)
  assert_true(collect_array_values(array.values()) == values)

  let empty_encoded = encode_array([], [])
  let empty = array_from_sql(empty_encoded[:])
  assert_eq(empty.dimensions, 0)
  assert_eq(empty.elements, 0)
  assert_true(collect_dimensions(empty.dimensions()) == [])
  assert_true(collect_array_values(empty.values()) == [])

  assert_invalid_input(
    try? encode_array([ArrayDimension::new(-1, 1)], [Some(b"x")]),
    "invalid dimension size",
  )
  assert_invalid_input(
    try? encode_array(
      [ArrayDimension::new(46341, 1), ArrayDimension::new(46341, 1)],
      [],
    ),
    "too many array elements",
  )
  assert_invalid_input(
    try? encode_array([ArrayDimension::new(2, 1)], [Some(b"x")]),
    "array element count does not match dimensions",
  )
  assert_invalid_input(
    try? array_from_sql(bytes_of([255, 255, 255, 255])[:]),
    "invalid dimension count",
  )

  let invalid_size = @buffer.new()
  invalid_size.write_int_be(1)
  invalid_size.write_int_be(0)
  invalid_size.write_uint_be(25U)
  invalid_size.write_int_be(-1)
  invalid_size.write_int_be(1)
  assert_invalid_input(
    try? array_from_sql(invalid_size.to_bytes()[:]),
    "invalid dimension size",
  )

  let invalid_value = @buffer.new()
  invalid_value.write_int_be(1)
  invalid_value.write_int_be(0)
  invalid_value.write_uint_be(25U)
  invalid_value.write_int_be(1)
  invalid_value.write_int_be(1)
  invalid_value.write_int_be(-2)
  let invalid_array = array_from_sql(invalid_value.to_bytes()[:])
  let invalid_values = invalid_array.values()
  assert_invalid_input(try? invalid_values.next(), "invalid value length")

  let undrained = @buffer.new()
  undrained.write_int_be(0)
  undrained.write_int_be(0)
  undrained.write_uint_be(25U)
  undrained.write_byte(1)
  let undrained_array = array_from_sql(undrained.to_bytes()[:])
  assert_invalid_input(
    try? undrained_array.values().next(),
    "invalid message length: arrayvalue not drained",
  )
}

///|
test "protocol types range codecs handle empty, bounded, null, and malformed payloads" {
  let empty_buf = @buffer.new()
  empty_range_to_sql(empty_buf)
  assert_true(range_from_sql(empty_buf.to_bytes()[:]) is Empty)
  assert_invalid_input(
    try? range_from_sql(bytes_of([1, 0])[:]),
    "invalid message size",
  )

  let bounded = encode_range(Inclusive(Some(b"lo")), Unbounded)
  expect_nonempty_range(
    range_from_sql(bounded[:]),
    Inclusive(Some(b"lo")),
    Unbounded,
  )

  let nullable = encode_range(Exclusive(None), Inclusive(Some(b"hi")))
  expect_nonempty_range(
    range_from_sql(nullable[:]),
    Exclusive(None),
    Inclusive(Some(b"hi")),
  )

  let trailing = @buffer.new()
  trailing.write_bytes(bounded)
  trailing.write_byte(0)
  assert_invalid_input(
    try? range_from_sql(trailing.to_bytes()[:]),
    "invalid message size",
  )
  assert_invalid_input(
    try? range_from_sql(bytes_of([0, 0, 0, 0, 2, b'a'])[:]),
    "invalid message size",
  )
}

///|
test "protocol types geometry codecs round trip" {
  let point_buf = @buffer.new()
  point_to_sql(1.5, -2.0, point_buf)
  let point = point_from_sql(point_buf.to_bytes()[:])
  assert_eq(point.x, 1.5)
  assert_eq(point.y, -2.0)

  let box_buf = @buffer.new()
  box_to_sql(4.0, 5.0, -1.0, -2.0, box_buf)
  let box = box_from_sql(box_buf.to_bytes()[:])
  assert_eq(box.upper_right.x, 4.0)
  assert_eq(box.upper_right.y, 5.0)
  assert_eq(box.lower_left.x, -1.0)
  assert_eq(box.lower_left.y, -2.0)

  let path_buf = @buffer.new()
  path_to_sql(true, [(1.0, 2.0), (3.0, 4.0)].iter(), path_buf)
  let path = path_from_sql(path_buf.to_bytes()[:])
  assert_eq(path.closed, true)
  assert_eq(path.points, 2)
  assert_true(collect_path_points(path.points()) == [(1.0, 2.0), (3.0, 4.0)])

  let broken_path = @buffer.new()
  broken_path.write_byte(0)
  broken_path.write_int_be(-1)
  assert_invalid_input(
    try? path_from_sql(broken_path.to_bytes()[:]),
    "invalid point count",
  )

  let wrong_path_len = @buffer.new()
  wrong_path_len.write_byte(0)
  wrong_path_len.write_int_be(2)
  wrong_path_len.write_bytes(bytes_of([0, 1, 2]))
  assert_invalid_input(
    try? path_from_sql(wrong_path_len.to_bytes()[:]),
    "invalid message length",
  )
}

///|
test "protocol types inet codecs cover ipv4, ipv6, and validation" {
  let ipv4 = Ipv4Addr::from_octets(bytes_of([127, 0, 0, 1])[:])
  assert_eq(ipv4.octets(), bytes_of([127, 0, 0, 1])[:])
  let inet4_buf = @buffer.new()
  inet_to_sql(V4(ipv4), 24, inet4_buf)
  let inet4 = inet_from_sql(inet4_buf.to_bytes()[:])
  assert_eq(inet4.netmask, (24).to_byte())
  guard inet4.addr is V4(parsed4) else { fail("expected IPv4 inet") }
  assert_eq(parsed4.octets(), bytes_of([127, 0, 0, 1])[:])

  let ipv6 = Ipv6Addr::from_octets(
    bytes_of([0, 1, 0, 2, 0, 3, 0, 4, 0, 5, 0, 6, 0, 7, 0, 8])[:],
  )
  assert_eq(
    ipv6.octets(),
    bytes_of([0, 1, 0, 2, 0, 3, 0, 4, 0, 5, 0, 6, 0, 7, 0, 8])[:],
  )
  let inet6_buf = @buffer.new()
  inet_to_sql(V6(ipv6), 64, inet6_buf)
  let inet6 = inet_from_sql(inet6_buf.to_bytes()[:])
  assert_eq(inet6.netmask, (64).to_byte())
  guard inet6.addr is V6(parsed6) else { fail("expected IPv6 inet") }
  assert_eq(
    parsed6.octets(),
    bytes_of([0, 1, 0, 2, 0, 3, 0, 4, 0, 5, 0, 6, 0, 7, 0, 8])[:],
  )

  assert_invalid_input(
    try? Ipv4Addr::from_octets(bytes_of([1, 2, 3])[:]),
    "invalid IPv4 length",
  )
  assert_invalid_input(
    try? Ipv6Addr::from_octets(bytes_of([1, 2, 3])[:]),
    "invalid IPv6 length",
  )
  assert_invalid_input(
    try? inet_from_sql(bytes_of([2, 33, 0, 4, 1, 2, 3, 4])[:]),
    "invalid IPv4 netmask",
  )
  assert_invalid_input(
    try? inet_from_sql(
      bytes_of([3, 129, 0, 16, 0, 1, 0, 2, 0, 3, 0, 4, 0, 5, 0, 6, 0, 7, 0, 8])[:],
    ),
    "invalid IPv6 netmask",
  )
  assert_invalid_input(
    try? inet_from_sql(bytes_of([9, 0, 0, 4, 1, 2, 3, 4])[:]),
    "invalid IP family",
  )
}

///|
test "protocol types tree-query codecs require version byte 1" {
  let ltree_buf = @buffer.new()
  ltree_to_sql(b"a.b"[:], ltree_buf)
  assert_eq(ltree_from_sql(ltree_buf.to_bytes()[:]), b"a.b")
  assert_invalid_input(
    try? ltree_from_sql(bytes_of([2, b'a'])[:]),
    "ltree version 1 only supported",
  )

  let lquery_buf = @buffer.new()
  lquery_to_sql(b"*.x"[:], lquery_buf)
  assert_eq(lquery_from_sql(lquery_buf.to_bytes()[:]), b"*.x")
  assert_invalid_input(
    try? lquery_from_sql(bytes_of([2, b'a'])[:]),
    "lquery version 1 only supported",
  )

  let ltxtquery_buf = @buffer.new()
  ltxtquery_to_sql(b"foo & bar"[:], ltxtquery_buf)
  assert_eq(ltxtquery_from_sql(ltxtquery_buf.to_bytes()[:]), b"foo & bar")
  assert_invalid_input(
    try? ltxtquery_from_sql(bytes_of([2, b'a'])[:]),
    "ltxtquery version 1 only supported",
  )
}
