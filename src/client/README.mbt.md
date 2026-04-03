# Postgres Client

An async PostgreSQL client with an explicit `Client + Connection` split.

`connect` returns two values:

- `Client`: submits requests such as `prepare`, `query`, `simple_query`, `copy_in`, and `copy_out`
- `Connection`: owns the socket and must be driven by calling `run`

## Connect

```mbt check
///|
async fn _connect_example() -> Unit {
  let config = @client.Config::new(
    "127.0.0.1",
    user="postgres",
    database="app",
    password="secret",
    port=5432,
    ssl_mode=@client.SslMode::disable(),
    application_name="my-service",
  )
  let (client, connection) = @client.connect(config)
  ignore(client)
  ignore(connection)
}
```

## Query

Extended queries return a `RowStream`. Rows are strongly typed through `FromSql`.

```mbt check
///|
async fn _query_example(client : @client.Client) -> Unit {
  let stream = client.query(
    "select 1::int4 as id, 'moonbit'::text as name, true::bool as enabled",
  )
  let rows = stream.collect()
  let row = rows[0]
  let id : Int = row.get_name("id")
  let name : String = row.get_name("name")
  let enabled : Bool = row.get_name("enabled")
  ignore(id)
  ignore(name)
  ignore(enabled)
}
```

Streams can also be consumed incrementally and then finished explicitly to
drain buffered responses and finalize the query summary. The driver only keeps
a small bounded response buffer per request, so a paused stream will eventually
apply backpressure to later pipelined requests.

```mbt check
///|
async fn _streaming_query_example(client : @client.Client) -> Unit {
  let stream = client.query("select generate_series(1, 3)::int4 as value")
  guard stream.next() is Some(row) else { return }
  let value : Int = row.get_name("value")
  let summary = stream.finish()
  ignore(value)
  ignore(summary.row_count)
}
```

## Simple Query

Simple queries expose result frames through `SimpleQueryStream`.

```mbt check
///|
async fn _simple_query_example(client : @client.Client) -> Unit {
  let stream = client.simple_query("select 'hello'::text as greeting")
  ignore(stream.next())
  stream.finish()
}
```

## Transactions

```mbt check
///|
async fn _transaction_example(client : @client.Client) -> Unit {
  let tx = client.transaction()
  let _ = tx.execute("insert into items(id) values (1)")
  tx.rollback()
}
```

## Errors

Driver operations raise `ClientError`. Type mismatches detected before encoding or decoding raise `ClientError::WrongType`.

```mbt check
///|
async fn _handle_error_example(client : @client.Client) -> Unit {
  let result = try? client.query_one("select 1 / 0")
  match result {
    Err(@client.ClientError::Database(err)) => {
      ignore(err.code)
      ignore(err.message)
    }
    _ => ()
  }
}
```
