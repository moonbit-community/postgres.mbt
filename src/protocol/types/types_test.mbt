///|
test "bool" {
  let buf = @buffer.new()
  bool_to_sql(true, buf)
  assert_eq(try! bool_from_sql(buf.to_bytes()[:]), true)
  let buf2 = @buffer.new()
  bool_to_sql(false, buf2)
  assert_eq(try! bool_from_sql(buf2.to_bytes()[:]), false)
}

///|
test "int2" {
  let buf = @buffer.new()
  try! int2_to_sql(0x0102, buf)
  assert_eq(try! int2_from_sql(buf.to_bytes()[:]), 0x0102)
}

///|
test "int4" {
  let buf = @buffer.new()
  try! int4_to_sql(0x0102_0304, buf)
  assert_eq(try! int4_from_sql(buf.to_bytes()[:]), 0x0102_0304)
}

///|
test "int8" {
  let buf = @buffer.new()
  int8_to_sql(0x0102_0304_0506_0708L, buf)
  assert_eq(try! int8_from_sql(buf.to_bytes()[:]), 0x0102_0304_0506_0708L)
}

///|
test "float4" {
  let buf = @buffer.new()
  float4_to_sql(10343.95, buf)
  assert_eq(try! float4_from_sql(buf.to_bytes()[:]), 10343.95)
}

///|
test "float8" {
  let buf = @buffer.new()
  float8_to_sql(10343.95, buf)
  assert_eq(try! float8_from_sql(buf.to_bytes()[:]), 10343.95)
}

///|
test "hstore" {
  let map = Map::from_array([(b"hello", Some(b"world")), (b"hola", None)])
  let entries : Array[(BytesView, BytesView?)] = []
  for k, v in map {
    let v_view = match v {
      Some(val) => Some(val[:])
      None => None
    }
    entries.push((k[:], v_view))
  }
  let buf = @buffer.new()
  try! hstore_to_sql(entries.iter(), buf)
  let parsed = try! hstore_from_sql(buf.to_bytes()[:])
  let out : Map[Bytes, Bytes?] = Map::new()
  while (try! parsed.next()) is Some((k, v)) {
    out[k] = v
  }
  assert_true(out.equal(map))
}

///|
test "varbit" {
  let len = 12
  let bits : Array[Byte] = b"\x2b\x0f".to_array()
  let buf = @buffer.new()
  try! varbit_to_sql(len, bits.iter(), buf)
  let out = try! varbit_from_sql(buf.to_bytes()[:])
  assert_eq(out.len(), len)
  assert_eq(out.bytes().to_bytes(), Bytes::from_array(bits[:]))
}

///|
test "array" {
  let dimensions : Array[ArrayDimension] = [
    ArrayDimension::new(1, 10),
    ArrayDimension::new(2, 0),
  ]
  let values : Array[Bytes?] = [None, Some(b"hello")]
  let buf = @buffer.new()
  try! array_to_sql(
    dimensions.iter(),
    10U,
    values.iter(),
    fn(v, b) {
      match v {
        Some(val) => {
          b.write_bytesview(val[:])
          @proto.IsNull::No
        }
        None => @proto.IsNull::Yes
      }
    },
    buf,
  )
  let array = try! array_from_sql(buf.to_bytes()[:])
  assert_true(array.has_nulls())
  assert_eq(array.element_type(), 10U)
  let dims : Array[ArrayDimension] = []
  let it_dims = array.dimensions()
  while (try! it_dims.next()) is Some(d) {
    dims.push(d)
  }
  assert_true(dims.equal(dimensions))
  let vals : Array[Bytes?] = []
  let it_vals = array.values()
  while (try! it_vals.next()) is Some(v) {
    vals.push(v)
  }
  assert_true(vals.equal(values))
}

///|
test "non_null_array" {
  let dimensions : Array[ArrayDimension] = [
    ArrayDimension::new(1, 10),
    ArrayDimension::new(2, 0),
  ]
  let values : Array[Bytes?] = [Some(b"hola"), Some(b"hello")]
  let buf = @buffer.new()
  try! array_to_sql(
    dimensions.iter(),
    10U,
    values.iter(),
    fn(v, b) {
      match v {
        Some(val) => {
          b.write_bytesview(val[:])
          @proto.IsNull::No
        }
        None => @proto.IsNull::Yes
      }
    },
    buf,
  )
  let array = try! array_from_sql(buf.to_bytes()[:])
  assert_true(!array.has_nulls())
  assert_eq(array.element_type(), 10U)
  let dims : Array[ArrayDimension] = []
  let it_dims = array.dimensions()
  while (try! it_dims.next()) is Some(d) {
    dims.push(d)
  }
  assert_true(dims.equal(dimensions))
  let vals : Array[Bytes?] = []
  let it_vals = array.values()
  while (try! it_vals.next()) is Some(v) {
    vals.push(v)
  }
  assert_true(vals.equal(values))
}

///|
test "array_too_many_elements" {
  let buf = @buffer.new()
  buf.write_int_be(2)
  buf.write_int_be(0)
  buf.write_uint_be(0U)
  buf.write_int_be(0x7fff_ffff)
  buf.write_int_be(0)
  buf.write_int_be(2)
  buf.write_int_be(0)
  assert_true((try? array_from_sql(buf.to_bytes()[:])) is Err(_))
}

///|
test "ltree" {
  let buf = @buffer.new()
  ltree_to_sql(b"A.B.C", buf)
  let expected = b"\x01A.B.C"
  assert_eq(buf.to_bytes(), expected)
  assert_true(try! (ltree_from_sql(expected[:]) == b"A.B.C"))
}

///|
test "ltree_wrong_version" {
  let bad = b"\x02A.B.C"
  assert_true((try? ltree_from_sql(bad[:])) is Err(_))
}

///|
test "lquery" {
  let buf = @buffer.new()
  lquery_to_sql(b"A.B.C", buf)
  let expected = b"\x01A.B.C"
  assert_eq(buf.to_bytes(), expected)
  assert_true(try! (lquery_from_sql(expected[:]) == b"A.B.C"))
}

///|
test "lquery_wrong_version" {
  let bad = b"\x02A.B.C"
  assert_true((try? lquery_from_sql(bad[:])) is Err(_))
}

///|
test "ltxtquery" {
  let buf = @buffer.new()
  ltxtquery_to_sql(b"a & b*", buf)
  let expected = b"\x01a & b*"
  assert_eq(buf.to_bytes(), expected)
  assert_true(try! (ltxtquery_from_sql(expected[:]) == b"a & b*"))
}

///|
test "ltxtquery_wrong_version" {
  let bad = b"\x02a & b*"
  assert_true((try? ltxtquery_from_sql(bad[:])) is Err(_))
}
