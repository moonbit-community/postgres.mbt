///|
fn transaction_row_values(rows : Array[@client.Row]) -> Array[Int] raise {
  let values : Array[Int] = []
  for row in rows {
    values.push(row.get_name("value"))
  }
  values
}

///|
/// This verifies the client-side transaction helpers around explicit builders, savepoints, prepared statements, portals, and rollback.
/// The test starts one builder-configured transaction, exercises both named and unnamed savepoints, and then opens a second plain transaction to cover the default `BEGIN` path.
async test "integration transaction builder savepoints and raw statement helpers" {
  guard integration_config() is Some(config) else { return }
  @async.with_task_group(group => {
    let (client, connection) = @client.connect(
      as_client_config(
        config,
        application_name="moonbit-postgres-client-tx-extra",
      ),
    )
    group.spawn_bg(() => connection.run())

    let tx = client
      .build_transaction()
      .isolation_level("SERIALIZABLE")
      .read_only(enabled=false)
      .deferrable(enabled=false)
      .start()
    tx.batch_execute("create temp table moon_client_tx_extra(value int4)")

    let insert_statement = tx.prepare(
      "insert into moon_client_tx_extra(value) values ($1::int4)",
    )
    let typed_statement = tx.prepare_typed("select $1::int4 as value", [
      @client.Type::int4(),
    ])
    let select_statement = tx.prepare(
      "select value from moon_client_tx_extra order by value",
    )

    assert_eq(
      transaction_row_values(
        tx
        .query_statement(typed_statement, params=[7 as &@client.ToSql])
        .collect(),
      ),
      [7],
    )
    assert_eq(tx.execute_raw(insert_statement, params=[1 as &@client.ToSql]), 1)

    let named = tx.savepoint("named_inner")
    assert_eq(
      named.execute_raw(insert_statement, params=[2 as &@client.ToSql]),
      1,
    )
    assert_eq(
      transaction_row_values(
        named
        .query("select value from moon_client_tx_extra order by value")
        .collect(),
      ),
      [1, 2],
    )
    named.rollback()

    let nested = tx.transaction()
    assert_eq(
      nested.execute(
        "insert into moon_client_tx_extra(value) values ($1::int4)",
        params=[3 as &@client.ToSql],
      ),
      1,
    )
    let portal = nested.bind(select_statement)
    assert_eq(
      transaction_row_values(nested.query_portal(portal, 1).collect()),
      [1],
    )
    assert_eq(
      transaction_row_values(nested.query_portal(portal, 8).collect()),
      [3],
    )
    portal.close()
    nested.commit()

    let isolation : String = tx.query("show transaction_isolation").collect()[0].get_name(
      "transaction_isolation",
    )
    let read_only : String = tx.query("show transaction_read_only").collect()[0].get_name(
      "transaction_read_only",
    )
    let deferrable : String = tx.query("show transaction_deferrable").collect()[0].get_name(
      "transaction_deferrable",
    )
    assert_eq(isolation, "serializable")
    assert_eq(read_only, "off")
    assert_eq(deferrable, "off")
    assert_eq(
      transaction_row_values(
        tx
        .query("select value from moon_client_tx_extra order by value")
        .collect(),
      ),
      [1, 3],
    )

    insert_statement.close()
    typed_statement.close()
    select_statement.close()
    tx.commit()

    client.check_connection()
    let total : Int = client
      .query_one("select sum(value)::int4 as value from moon_client_tx_extra")
      .get_name("value")
    assert_eq(total, 4)

    let follow_up = client.transaction()
    assert_eq(
      transaction_row_values(
        follow_up.query("select 9::int4 as value").collect(),
      ),
      [9],
    )
    follow_up.rollback()

    client.close()
  })
}

///|
/// This verifies the default transaction-builder path together with direct named-savepoint commit and nested rollback.
/// The outer transaction starts from `build_transaction().start()` with no clauses, commits one named savepoint, rolls back one unnamed nested scope, and then commits the surviving rows.
async test "integration transaction default builder and named savepoint commit" {
  guard integration_config() is Some(config) else { return }
  @async.with_task_group(group => {
    let (client, connection) = @client.connect(
      as_client_config(
        config,
        application_name="moonbit-postgres-client-tx-default",
      ),
    )
    group.spawn_bg(() => connection.run())

    let tx = client.build_transaction().start()
    tx.batch_execute("create temp table moon_client_tx_default(value int4)")
    assert_eq(
      tx.execute(
        "insert into moon_client_tx_default(value) values ($1::int4)",
        params=[1 as &@client.ToSql],
      ),
      1,
    )

    let named = tx.savepoint("named_commit")
    assert_eq(
      named.execute(
        "insert into moon_client_tx_default(value) values ($1::int4)",
        params=[2 as &@client.ToSql],
      ),
      1,
    )
    named.commit()

    let nested = tx.transaction()
    assert_eq(
      nested.execute(
        "insert into moon_client_tx_default(value) values ($1::int4)",
        params=[3 as &@client.ToSql],
      ),
      1,
    )
    nested.rollback()

    assert_eq(
      transaction_row_values(
        tx
        .query("select value from moon_client_tx_default order by value")
        .collect(),
      ),
      [1, 2],
    )
    tx.commit()

    client.check_connection()
    assert_eq(
      transaction_row_values(
        client
        .query("select value from moon_client_tx_default order by value")
        .collect(),
      ),
      [1, 2],
    )

    client.close()
  })
}
