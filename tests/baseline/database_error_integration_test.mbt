///|
/// Server source locations vary by version; only their presence is contractual.
fn assert_database_error_source(err : @client.DatabaseError) -> Unit raise {
  assert_true(err.file is Some(file) && !file.is_empty())
  assert_true(err.line is Some(line) && line > 0U)
  assert_true(err.routine is Some(routine) && !routine.is_empty())
}

///|
async test "integration database error distinguishes constraints and not null columns" {
  guard integration_config() is Some(config) else { return }
  @async.with_task_group(group => {
    let client = start_client(
      as_client_config(
        config,
        application_name="moonbit-postgres-error-objects",
      ),
      group,
    )
    client.batch_execute(
      (
        #|create temp table error_objects (
        #|  email text not null, username text not null,
        #|  constraint error_email_unique unique (email),
        #|  constraint error_username_unique unique (username)
        #|);
        #|insert into error_objects values ('a@example.com', 'alice');
      ),
    )
    let schema : String = client
      .query_one(
        "select nspname::text as name from pg_namespace where oid = pg_my_temp_schema()",
      )
      .get_name("name")
    let email = expect_database_error(
      expect_error_async(() => {
        client.execute(
          "insert into error_objects values ('a@example.com', 'bob')",
        )
      }),
    )
    let username = expect_database_error(
      expect_error_async(() => {
        client.batch_execute(
          "insert into error_objects values ('b@example.com', 'alice')",
        )
      }),
    )
    @debug.assert_eq(email.code, Some("23505"))
    @debug.assert_eq(username.code, email.code)
    @debug.assert_eq(email.constraint, Some("error_email_unique"))
    @debug.assert_eq(username.constraint, Some("error_username_unique"))
    assert_true(email != username)
    for err in [email, username] {
      @debug.assert_eq(err.schema, Some(schema))
      @debug.assert_eq(err.table, Some("error_objects"))
      @debug.assert_eq(err.severity_nonlocalized, Some("ERROR"))
      assert_database_error_source(err)
    }
    let not_null = expect_database_error(
      expect_error_async(() => {
        client.execute("insert into error_objects values (null, 'carol')")
      }),
    )
    @debug.assert_eq(not_null.code, Some("23502"))
    @debug.assert_eq(not_null.schema, Some(schema))
    @debug.assert_eq(not_null.table, Some("error_objects"))
    @debug.assert_eq(not_null.column, Some("email"))
    // The same constraint metadata survives transaction rollback and COPY cleanup.
    let tx_error = expect_database_error(
      expect_error_async(() => {
        client.with_transaction(tx => {
          tx.execute(
            "insert into error_objects values ('a@example.com', 'dave')",
          )
        })
      }),
    )
    @debug.assert_eq(tx_error.constraint, Some("error_email_unique"))
    let copy_error = expect_database_error(
      expect_error_async(() => {
        client.with_copy_in("copy error_objects from stdin", sink => {
          sink.send(@proto.utf8_encode("a@example.com\terin\n"))
          sink.finish()
        })
      }),
    )
    @debug.assert_eq(copy_error.constraint, Some("error_email_unique"))
    @debug.assert_eq(copy_error.table, Some("error_objects"))
    let count : Int = client
      .query_one("select count(*)::int4 as count from error_objects")
      .get_name("count")
    assert_eq(count, 1)
    client.close()
  })
}

///|
async test "integration database error query position counts Unicode characters" {
  guard integration_config() is Some(config) else { return }
  @async.with_task_group(group => {
    let client = start_client(
      as_client_config(
        config,
        application_name="moonbit-postgres-error-position",
      ),
      group,
    )
    // The missing identifier starts at character 13, byte 16, UTF-16 unit 14.
    for simple in [false, true] {
      let err = expect_database_error(
        expect_error_async(() => {
          if simple {
            client.batch_execute("select '😀', missing_column")
          } else {
            client.query_one("select '😀', missing_column") |> ignore
          }
        }),
      )
      @debug.assert_eq(err.code, Some("42703"))
      @debug.assert_eq(err.position, Some(13U))
      @debug.assert_eq(err.internal_position, None)
    }
    let probe : Int = client
      .query_one("select 42::int4 as value")
      .get_name("value")
    assert_eq(probe, 42)
    client.close()
  })
}

///|
async test "integration database error preserves internal query and context" {
  guard integration_config() is Some(config) else { return }
  @async.with_task_group(group => {
    let client = start_client(
      as_client_config(
        config,
        application_name="moonbit-postgres-error-internal",
      ),
      group,
    )
    client.batch_execute(
      (
        #|create function pg_temp.error_internal() returns void language plpgsql as $$
        #|begin
        #|  perform '😀', missing_internal_column;
        #|end
        #|$$;
      ),
    )
    let err = expect_database_error(
      expect_error_async(() => {
        client.query_one("select pg_temp.error_internal()")
      }),
    )
    @debug.assert_eq(err.code, Some("42703"))
    @debug.assert_eq(
      err.internal_query,
      Some("SELECT '😀', missing_internal_column"),
    )
    @debug.assert_eq(err.internal_position, Some(13U))
    @debug.assert_eq(err.position, None)
    assert_true(
      err.where_ is Some(context) && context.contains("error_internal"),
    )
    assert_database_error_source(err)
    let probe : Int = client
      .query_one("select 43::int4 as value")
      .get_name("value")
    assert_eq(probe, 43)
    client.close()
  })
}

///|
async test "integration database notice preserves object fields and multiline text" {
  guard integration_config() is Some(config) else { return }
  @async.with_task_group(group => {
    let client = start_client(
      as_client_config(config, application_name="moonbit-postgres-error-notice"),
      group,
    )
    client.batch_execute(
      (
        #|do $$ begin
        #|  raise notice using message = '提示 😀', errcode = '23505',
        #|    schema = 'notice_schema', table = 'notice_table', column = 'notice_column',
        #|    datatype = 'notice_type', constraint = 'notice_constraint',
        #|    detail = E'first\nsecond', hint = E'try\nagain';
        #|end $$;
      ),
    )
    let messages = collect_driver_async_messages(client, 1)
    guard messages[0] is Notice(notice) else { fail("expected notice") }
    @debug.assert_eq(notice.severity, Some("NOTICE"))
    @debug.assert_eq(notice.severity_nonlocalized, Some("NOTICE"))
    @debug.assert_eq(notice.code, Some("23505"))
    @debug.assert_eq(notice.message, "提示 😀")
    @debug.assert_eq(notice.schema, Some("notice_schema"))
    @debug.assert_eq(notice.table, Some("notice_table"))
    @debug.assert_eq(notice.column, Some("notice_column"))
    @debug.assert_eq(notice.datatype, Some("notice_type"))
    @debug.assert_eq(notice.constraint, Some("notice_constraint"))
    @debug.assert_eq(notice.detail, Some("first\nsecond"))
    @debug.assert_eq(notice.hint, Some("try\nagain"))
    assert_true(notice.where_ is Some(_))
    assert_database_error_source(notice)
    let probe : Int = client
      .query_one("select 44::int4 as value")
      .get_name("value")
    assert_eq(probe, 44)
    client.close()
  })
}

///|
async test "integration pool passes structured database errors and reuses connection" {
  guard integration_config() is Some(config) else { return }
  @async.with_task_group(group => {
    let pool = make_pool(
      group,
      as_client_config(config, application_name="moonbit-postgres-error-pool"),
      make_pool_config(1),
    )
    let before : Int = pool
      .query_one("select pg_backend_pid()::int4 as pid")
      .get_name("pid")
    let err = expect_database_error(
      expect_error_async(() => {
        pool.batch_execute(
          (
            #|do $$ begin
            #|  raise exception using message = 'pooled failure', errcode = '23505',
            #|    schema = 'pool_schema', table = 'pool_table', column = 'pool_column',
            #|    datatype = 'pool_type', constraint = 'pool_constraint';
            #|end $$;
          ),
        )
      }),
    )
    @debug.assert_eq(err.code, Some("23505"))
    @debug.assert_eq(err.schema, Some("pool_schema"))
    @debug.assert_eq(err.table, Some("pool_table"))
    @debug.assert_eq(err.column, Some("pool_column"))
    @debug.assert_eq(err.datatype, Some("pool_type"))
    @debug.assert_eq(err.constraint, Some("pool_constraint"))
    @debug.assert_eq(err.severity_nonlocalized, Some("ERROR"))
    assert_true(err.where_ is Some(_))
    assert_database_error_source(err)
    let after : Int = pool
      .query_one("select pg_backend_pid()::int4 as pid")
      .get_name("pid")
    assert_eq(after, before)
    pool.close()
  })
}
