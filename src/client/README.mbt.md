# Postgres Client

An async PostgreSQL client built on `moonbitlang/async`.

It currently provides:

- Connection startup with cleartext, `md5`, and `SCRAM-SHA-256` authentication
- `simple_query` for text SQL
- `query` for parameterized extended queries
- Text-format result decoding through `Row` and `QueryResult`

Current protocol limitations:

- Multiple result sets are rejected
- `COPY` is not exposed by `Client`
- Portal suspension is not exposed by `Client`

## Connect

Use `Client::connect` to open a connection and `close` it when finished.

```mbt check
///|
async fn _connect_example() -> Unit {
  let client = @client.Client::connect(
    "127.0.0.1",
    user="postgres",
    database="app",
    password="secret",
    port=5432,
    ssl_mode=@client.SslMode::disable(),
    application_name="my-service",
  )
  defer client.close()

  ignore(client.process_id())
  ignore(client.secret_key())
  ignore(client.parameter_status("server_version"))
}
```

`SslMode::disable()`, `SslMode::prefer()`, and `SslMode::require()` control TLS negotiation.

## Simple Query

`simple_query` is useful for plain SQL without bind parameters.

```mbt check
///|
async fn _simple_query_example(client : @client.Client) -> Unit {
  let result = client.simple_query(
    "select 1::text as id, 'hello'::text as name, null::text as note",
  )

  let row = result.rows()[0]
  let id = try! row.get_named_text("id")
  let name = try! row.get_named_text("name")
  let note = try! row.get_named_text("note")

  ignore(result.command_tag())
  ignore(result.row_count())
  ignore(id)
  ignore(name)
  ignore(note)
}
```

`Row::get_named_text` returns `String??`:

- `None`: the column does not exist
- `Some(None)`: the column is SQL `NULL`
- `Some(Some(text))`: the column contains text

## Parameterized Query

`query` uses the extended query protocol and accepts `QueryParam` values.

```mbt check
///|
async fn _query_example(client : @client.Client) -> Unit {
  let result = client.query(
    "select $1::int4 as id, $2::text as name, $3::boolean as enabled",
    params=[
      @client.QueryParam::int(7),
      @client.QueryParam::string("moonbit"),
      @client.QueryParam::bool(true),
    ],
  )

  let row = result.rows()[0]
  let id = try! row.get_named_text("id")
  let name = try! row.get_named_text("name")
  let enabled = try! row.get_named_text("enabled")

  ignore(id)
  ignore(name)
  ignore(enabled)
}
```

Supported parameter helpers include `null`, `bytes`, `string`, `bool`, `int`, `int64`, and `double`.

## Errors

Driver operations raise `ClientError`.

```mbt check
///|
async fn _handle_error_example(client : @client.Client) -> Unit {
  let result = try? client.simple_query("select 1 / 0")
  match result {
    Ok(_) => ()
    Err(@client.ClientError::Database(err)) => {
      ignore(err.severity())
      ignore(err.code())
      ignore(err.message())
      ignore(err.detail())
      ignore(err.hint())
    }
    Err(_) => ()
  }
}
```

The main error categories are:

- `Database(DatabaseError)`: server returned an error response
- `Authentication(String)`: password or authentication state problem
- `Unsupported(String)`: protocol branch not implemented by `Client`
- `UnexpectedMessage(String)`: server reply did not match the expected flow
- `Ssl(String)`: TLS negotiation failure
