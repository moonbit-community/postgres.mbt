// Helpers that encode client requests into PostgreSQL frontend messages.

///|
/// Encode a simple-query protocol request.
fn simple_query_bytes(sql : String) -> Bytes raise {
  let buf = @buffer.new()
  @frontend.query(@proto.utf8_encode(sql)[:], buf)
  buf.to_bytes()
}

///|
/// Encode a standalone `Sync`.
fn sync_bytes() -> Bytes {
  let buf = @buffer.new()
  @frontend.sync(buf)
  buf.to_bytes()
}

///|
/// Encode a graceful connection termination request.
fn terminate_bytes() -> Bytes {
  let buf = @buffer.new()
  @frontend.terminate(buf)
  buf.to_bytes()
}

///|
/// Encode `Close` followed by `Sync` for a statement or portal.
fn close_bytes(kind : Byte, name : BytesView) -> Bytes raise {
  let buf = @buffer.new()
  @frontend.close(kind, name, buf)
  @frontend.sync(buf)
  buf.to_bytes()
}

///|
/// Encode Parse + Describe + Sync for a prepared statement.
fn prepare_bytes(
  name : BytesView,
  sql : String,
  types : Array[Type],
) -> Bytes raise {
  let buf = @buffer.new()
  @frontend.parse(
    name,
    @proto.utf8_encode(sql)[:],
    types.map(t => t.oid).iter(),
    buf,
  )
  @frontend.describe(b'S', name, buf)
  @frontend.sync(buf)
  buf.to_bytes()
}

///|
/// Encode Bind + Execute + Sync for a prepared statement execution.
fn execute_statement_bytes(
  statement_name : BytesView,
  param_types : Array[Type],
  params : Array[&ToSql],
) -> Bytes raise {
  let buf = @buffer.new()
  write_bind(buf, b""[:], statement_name, param_types, params, true)
  @frontend.execute(b""[:], 0, buf)
  @frontend.sync(buf)
  buf.to_bytes()
}

///|
/// Encode Bind + Sync for portal creation.
fn bind_portal_bytes(
  portal_name : BytesView,
  statement_name : BytesView,
  param_types : Array[Type],
  params : Array[&ToSql],
) -> Bytes raise {
  let buf = @buffer.new()
  write_bind(buf, portal_name, statement_name, param_types, params, true)
  @frontend.sync(buf)
  buf.to_bytes()
}

///|
/// Encode Execute + Sync for portal execution.
fn execute_portal_bytes(portal_name : BytesView, max_rows : Int) -> Bytes raise {
  let buf = @buffer.new()
  @frontend.execute(portal_name, max_rows, buf)
  @frontend.sync(buf)
  buf.to_bytes()
}

///|
/// Serialized parameter payload plus its chosen wire format.
priv struct EncodedParam {
  format : WireFormat
  value : Bytes?
}

///|
/// Serialize one query parameter after validating type compatibility.
fn encode_param(param : &ToSql, type_ : Type) -> EncodedParam raise {
  guard param.accepts(type_) else {
    raise wrong_type_error(param.moonbit_type_name(), type_)
  }
  let payload = @buffer.new()
  let value = match param.to_sql(type_, payload) {
    @proto.IsNull::Yes => None
    @proto.IsNull::No => Some(payload.to_bytes())
  }
  { format: param.format(type_), value }
}

///|
/// Write one encoded parameter into the bind payload.
fn write_encoded_param(
  param : EncodedParam,
  payload : @buffer.Buffer,
) -> @proto.IsNull {
  match param.value {
    None => @proto.IsNull::Yes
    Some(bytes) => {
      payload.write_bytes(bytes)
      @proto.IsNull::No
    }
  }
}

///|
/// Encode a PostgreSQL `Bind` message and optionally describe the portal.
///
/// Each parameter is pre-serialized so codec failures happen before any bytes
/// are written to the request buffer.
fn write_bind(
  buf : @buffer.Buffer,
  portal : BytesView,
  statement : BytesView,
  param_types : Array[Type],
  params : Array[&ToSql],
  describe_portal : Bool,
) -> Unit raise {
  let encoded_params : Array[EncodedParam] = []
  for index, param in params {
    encoded_params.push(encode_param(param, param_types[index]))
  }
  let formats = encoded_params.map(param => encode_wire_format(param.format))
  @frontend.bind(
    portal,
    statement,
    formats.iter(),
    encoded_params.iter(),
    (param, payload) => write_encoded_param(param, payload),
    [1].iter(),
    buf,
  )
  if describe_portal {
    @frontend.describe(b'P', portal, buf)
  }
}
