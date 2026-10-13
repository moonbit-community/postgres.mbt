///|
pub async fn Pool::query_all(
  self : Pool,
  sql : String,
  params~ : Array[&@client.ToSql] = [],
  deadline? : Deadline,
  timeouts? : Timeouts,
) -> Array[@client.Row] {
  self.with_session(
    session => session.query_all(sql, params~),
    deadline?,
    timeouts?,
  )
}

///|
pub async fn Pool::query_one(
  self : Pool,
  sql : String,
  params~ : Array[&@client.ToSql] = [],
  deadline? : Deadline,
  timeouts? : Timeouts,
) -> @client.Row {
  self.with_session(
    session => session.query_one(sql, params~),
    deadline?,
    timeouts?,
  )
}

///|
pub async fn Pool::query_opt(
  self : Pool,
  sql : String,
  params~ : Array[&@client.ToSql] = [],
  deadline? : Deadline,
  timeouts? : Timeouts,
) -> @client.Row? {
  self.with_session(
    session => session.query_opt(sql, params~),
    deadline?,
    timeouts?,
  )
}

///|
pub async fn Pool::execute(
  self : Pool,
  sql : String,
  params~ : Array[&@client.ToSql] = [],
  deadline? : Deadline,
  timeouts? : Timeouts,
) -> UInt64 {
  self.with_session(
    session => session.execute(sql, params~),
    deadline?,
    timeouts?,
  )
}

///|
pub async fn Pool::query_typed_all(
  self : Pool,
  sql : String,
  param_types : Array[@client.Type],
  params~ : Array[&@client.ToSql] = [],
  deadline? : Deadline,
  timeouts? : Timeouts,
) -> Array[@client.Row] {
  self.with_session(
    session => session.query_typed_all(sql, param_types, params~),
    deadline?,
    timeouts?,
  )
}

///|
pub async fn Pool::query_typed_one(
  self : Pool,
  sql : String,
  param_types : Array[@client.Type],
  params~ : Array[&@client.ToSql] = [],
  deadline? : Deadline,
  timeouts? : Timeouts,
) -> @client.Row {
  self.with_session(
    session => session.query_typed_one(sql, param_types, params~),
    deadline?,
    timeouts?,
  )
}

///|
pub async fn Pool::query_typed_opt(
  self : Pool,
  sql : String,
  param_types : Array[@client.Type],
  params~ : Array[&@client.ToSql] = [],
  deadline? : Deadline,
  timeouts? : Timeouts,
) -> @client.Row? {
  self.with_session(
    session => session.query_typed_opt(sql, param_types, params~),
    deadline?,
    timeouts?,
  )
}

///|
pub async fn Pool::execute_typed(
  self : Pool,
  sql : String,
  param_types : Array[@client.Type],
  params~ : Array[&@client.ToSql] = [],
  deadline? : Deadline,
  timeouts? : Timeouts,
) -> UInt64 {
  self.with_session(
    session => session.execute_typed(sql, param_types, params~),
    deadline?,
    timeouts?,
  )
}

///|
pub async fn Pool::batch_execute(
  self : Pool,
  sql : String,
  deadline? : Deadline,
  timeouts? : Timeouts,
) -> Unit {
  self.with_session(session => session.batch_execute(sql), deadline?, timeouts?)
}

///|
pub async fn Pool::check_connection(
  self : Pool,
  deadline? : Deadline,
  timeouts? : Timeouts,
) -> Unit {
  self.with_session(session => session.check_connection(), deadline?, timeouts?)
}
