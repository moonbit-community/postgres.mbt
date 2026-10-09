///|
test "type descriptors include schema and full children in equality" {
  assert_eq(Type::int4().schema, Some("pg_catalog"))
  assert_eq(Type::int4_array().schema, Some("pg_catalog"))
  assert_eq(Type::unknown(99999U).schema, None)
  let a : Type = {
    oid: 90000U,
    name: "status",
    schema: Some("a"),
    kind: Enum(["ready"]),
  }
  let b : Type = { ..a, schema: Some("b"), }
  assert_false(a == b)
  let array_a : Type = {
    oid: 90001U,
    name: "_status",
    schema: Some("a"),
    kind: Array(a),
  }
  let array_b : Type = { ..array_a, kind: Array(b), }
  assert_false(array_a == array_b)
  let composite_a : Type = {
    ..array_a,
    kind: Composite([{ name: "value", type_: a, }]),
  }
  let composite_b : Type = {
    ..composite_a,
    kind: Composite([{ name: "value", type_: b, }]),
  }
  assert_false(composite_a == composite_b)
  assert_true(local_child_error(ClientError::UnsupportedRecursiveType(90000U)))
}

///|
async test "recursive catalog descriptors reuse siblings and reload after cache clear" {
  with_cancellation_test_client((group, client, next_request) => {
    for _ in 0..<2 {
      let active : Map[UInt, Unit] = Map([])
      let task = group.spawn(() => {
        cached_type_recursive(client.operation_context(), 90000U, active)
      })
      metadata_test_shape(next_request, 90000U, relid=91000U, typtype="c")
      metadata_test_catalog(
        next_request,
        typeinfo_composite_query,
        91000U,
        [Type::text(), Type::oid_type()],
        [
          [Some(b"left"), Some(metadata_test_oid(90001U))],
          [Some(b"right"), Some(metadata_test_oid(90001U))],
        ],
      )
      metadata_test_shape(next_request, 90001U, elem=90002U)
      metadata_test_shape(next_request, 90002U, typtype="e")
      metadata_test_catalog(
        next_request,
        typeinfo_enum_query,
        90002U,
        [Type::text()],
        [[Some(b"ready")], [Some(b"done")]],
      )
      let type_ = task.wait()
      assert_true(active.is_empty())
      assert_eq(type_.schema, Some("test_schema"))
      guard type_.kind is Composite(fields) else { fail("expected composite") }
      assert_eq(fields[0].type_, fields[1].type_)
      guard fields[0].type_.kind is Array(element) else {
        fail("expected array")
      }
      assert_eq(element.schema, Some("test_schema"))
      guard element.kind is Enum(labels) else { fail("expected enum") }
      assert_eq(labels, ["ready", "done"])
      assert_eq(cached_type(client.operation_context(), 90000U), type_)
      assert_eq(client.shared.types.get(90002U), Some(element))
      assert_true(client.shared.requests.try_get() is None)
      client.clear_type_cache()
      assert_true(client.shared.types.get(90000U) is None)
    }
  })
}

///|
async test "catalog domain range and pseudo preserve schema and full child types" {
  with_cancellation_test_client((group, client, next_request) => {
    for mode in 0..<3 {
      let oid = 90000U + mode.reinterpret_as_uint()
      let task = group.spawn(() => cached_type(client.operation_context(), oid))
      if mode == 0 {
        metadata_test_shape(next_request, oid, base=23U, typtype="d")
      } else if mode == 1 {
        metadata_test_shape(next_request, oid, subtype=23U, typtype="r")
      } else {
        metadata_test_shape(next_request, oid, typtype="p")
      }
      let type_ = task.wait()
      assert_eq(type_.schema, Some("test_schema"))
      match type_.kind {
        Domain(base) | Range(base) => assert_eq(base, Type::int4())
        Pseudo => assert_eq(mode, 2)
        _ => fail("unexpected kind")
      }
    }
  })
}

///|
async test "catalog cycles clear active nodes and never cache incomplete descriptors" {
  for mutual in [false, true] {
    with_cancellation_test_client((group, client, next_request) => {
      let active : Map[UInt, Unit] = Map([])
      for _ in 0..<2 {
        let task = group.spawn(allow_failure=true, () => {
          cached_type_recursive(client.operation_context(), 90000U, active)
        })
        if mutual {
          metadata_test_shape(next_request, 90000U, base=90001U, typtype="d")
          metadata_test_shape(next_request, 90001U, elem=90000U)
        } else {
          metadata_test_shape(next_request, 90000U, relid=91000U, typtype="c")
          metadata_test_catalog(
            next_request,
            typeinfo_composite_query,
            91000U,
            [Type::text(), Type::oid_type()],
            [[Some(b"self"), Some(metadata_test_oid(90000U))]],
          )
        }
        assert_true(
          expect_error_async(() => task.wait())
          is ClientError::UnsupportedRecursiveType(90000U),
        )
        assert_true(active.is_empty())
        assert_true(client.shared.types.get(90000U) is None)
        assert_true(client.shared.types.get(90001U) is None)
        assert_true(client.shared.requests.try_get() is None)
      }
    })
  }
}

///|
async test "catalog missing rows and database errors retain Unknown fallback" {
  for denied in [false, true] {
    with_cancellation_test_client((group, client, next_request) => {
      let task = group.spawn(() => {
        cached_type(client.operation_context(), 90000U)
      })
      metadata_test_catalog(
        next_request,
        typeinfo_query,
        90000U,
        [],
        [],
        database_error=denied,
      )
      let type_ = task.wait()
      assert_eq(type_, Type::unknown(90000U, name="oid_90000"))
      assert_eq(cached_type(client.operation_context(), 90000U), type_)
      assert_true(client.shared.requests.try_get() is None)
    })
  }
}
