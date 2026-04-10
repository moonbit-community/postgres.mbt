// Shared parsing helpers for backend protocol messages.

///|
/// Convert a PostgreSQL `RowDescription` into `Column` metadata.
///
/// The `type_` field is filled with the best local descriptor currently
/// available. Higher-level client code may later replace placeholder `Unknown`
/// descriptors with catalog-backed ones from the shared type cache.
fn parse_columns(body : @backend.RowDescriptionBody) -> Array[Column] raise {
  let columns : Array[Column] = []
  let fields = body.fields()
  for field = fields.next() {
    match field {
      None => break columns
      Some(field) => {
        // `resolve_type` may only know the builtin shape at parse time; later
        // cache lookups can enrich the descriptor without changing raw OIDs.
        columns.push({
          name: field.name_str(),
          table_oid: field.table_oid,
          column_id: field.column_id,
          type_: resolve_type(field.type_oid),
          type_size: field.type_size,
          type_modifier: field.type_modifier,
          format: field.format,
        })
        continue fields.next()
      }
    }
  }
}

///|
/// Materialize binary-format field payloads from a `DataRow`.
fn parse_binary_values(
  body : @backend.DataRowBody,
) -> Array[Bytes?] raise @proto.ProtocolError {
  let values : Array[Bytes?] = []
  let ranges = body.ranges()
  let buffer = body.buffer()
  for range = ranges.next() {
    match range {
      None => break values
      Some(None) => {
        values.push(None)
        continue ranges.next()
      }
      Some(Some(range)) => {
        // Copy the slice so the returned row owns stable bytes independent of
        // the temporary backend message buffer.
        values.push(Some(buffer[range.start:range.end].to_bytes()))
        continue ranges.next()
      }
    }
  }
}

///|
/// Materialize a text-format row for the simple query protocol.
fn parse_text_row(
  body : @backend.DataRowBody,
  columns : Array[String],
) -> SimpleQueryRow raise @proto.ProtocolError {
  let values : Array[String?] = []
  let ranges = body.ranges()
  let buffer = body.buffer()
  for range = ranges.next() {
    match range {
      None => break { columns, values }
      Some(None) => {
        values.push(None)
        continue ranges.next()
      }
      Some(Some(range)) => {
        // Simple-query rows are materialized as owned strings because the
        // underlying message buffer cannot escape this parser frame.
        values.push(Some(decode_utf8(buffer[range.start:range.end])))
        continue ranges.next()
      }
    }
  }
}

///|
/// Extract column labels from a `RowDescription`.
fn parse_column_names(
  body : @backend.RowDescriptionBody,
) -> Array[String] raise {
  let columns : Array[String] = []
  let fields = body.fields()
  for field = fields.next() {
    match field {
      None => break columns
      Some(field) => {
        columns.push(field.name_str())
        continue fields.next()
      }
    }
  }
}

///|
/// Collect column format codes from a COPY response.
fn parse_copy_formats(formats : @backend.ColumnFormats) -> Array[Int] raise {
  let out : Array[Int] = []
  for format = formats.next() {
    match format {
      None => break out
      Some(format) => {
        out.push(format)
        continue formats.next()
      }
    }
  }
}

///|
/// Parse PostgreSQL error fields into a structured `DatabaseError`.
fn parse_database_error(
  fields : @backend.ErrorFields,
) -> DatabaseError raise @proto.ProtocolError {
  let mut severity = None
  let mut code = None
  let mut message = None
  let mut detail = None
  let mut hint = None
  // Preserve the subset of PostgreSQL error fields that the public
  // `DatabaseError` struct exposes; all other tags are intentionally ignored.
  for field = fields.next() {
    match field {
      None =>
        break {
          severity,
          code,
          message: message.unwrap_or("database error"),
          detail,
          hint,
        }
      Some(field) => {
        let value = decode_utf8(field.value_bytes())
        match field.type_ {
          b'S' | b'V' => severity = Some(value)
          b'C' => code = Some(value)
          b'M' => message = Some(value)
          b'D' => detail = Some(value)
          b'H' => hint = Some(value)
          _ => ()
        }
        continue fields.next()
      }
    }
  }
}

///|
/// Decode protocol UTF-8 and normalize decoder failures to `ProtocolError`.
fn decode_utf8(bytes : BytesView) -> String raise @proto.ProtocolError {
  @utf8.decode(bytes) catch {
    _ => raise @proto.ProtocolError::InvalidInput("invalid UTF-8")
  }
}

///|
/// Merge a later `RowDescription` with already-resolved column metadata.
///
/// Extended-query helpers often know column types before the first row arrives.
/// When PostgreSQL sends another `RowDescription` during execution, this helper
/// verifies that the OIDs match and preserves the richer cached `Type` values.
fn merge_stream_columns(
  current : Array[Column],
  body : @backend.RowDescriptionBody,
) -> Array[Column] raise {
  let described = parse_columns(body)
  if current.is_empty() {
    // Streams created without earlier prepare metadata accept the runtime row
    // description verbatim the first time they see it.
    return described
  }
  guard current.length() == described.length() else {
    raise ClientError::Protocol(
      "row description column count mismatch: expected \{current.length().to_string()}, got \{described.length().to_string()}",
    )
  }
  let merged : Array[Column] = []
  for index, column in described {
    let resolved = current[index]
    guard resolved.type_.oid == column.type_.oid else {
      raise ClientError::Protocol(
        "row description type mismatch at column \{index.to_string()}: expected oid \{resolved.type_.oid.to_string()}, got \{column.type_.oid.to_string()}",
      )
    }
    merged.push({ ..column, type_: resolved.type_ })
  }
  merged
}

///|
/// Close a response queue with `err` and re-raise it.
///
/// Streams use this helper when they encounter a protocol state they cannot
/// recover from. Closing the queue prevents later consumers from hanging on a
/// stream that is already known to be invalid.
fn[X, Y] fail_response_stream(
  responses : @async.Queue[X],
  err : Error,
) -> Y raise {
  responses.close(error=err, clear=true)
  raise err
}
