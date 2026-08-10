///|
test "prepared cache promotes hits to MRU order" {
  let order = [1, 2, 3]
  let value = take_and_promote_index(order, 1)
  assert_eq(value, 2)
  assert_eq(order, [1, 3, 2])

  ignore(take_and_promote_index(order, 0))
  assert_eq(order, [3, 2, 1])
}

///|
test "prepared cache capacity and delayed-close predicates" {
  assert_false(statement_cache_needs_eviction(0, 0))
  assert_false(statement_cache_needs_eviction(1, 2))
  assert_true(statement_cache_needs_eviction(2, 2))
  assert_true(statement_cache_needs_eviction(3, 2))

  assert_false(evicted_statement_can_close(1, true))
  assert_false(evicted_statement_can_close(0, false))
  assert_true(evicted_statement_can_close(0, true))
}

///|
test "prepared cache parameter keys are independent snapshots" {
  let param_types = [@client.Type::int4(), @client.Type::text()]
  let cached = snapshot_statement_cache_param_types(param_types)
  param_types[0] = @client.Type::bool()
  param_types.push(@client.Type::int8())

  assert_true(cached == [@client.Type::int4(), @client.Type::text()])
  assert_true(param_types != cached)
}
