///|
pub async fn Session::query_all(
  self : Session,
  sql : String,
  params~ : Array[&@client.ToSql] = [],
  deadline? : Deadline,
) -> Array[@client.Row] {
  self.run_operation(
    client => {
      cached_query(self.state, client, sql, [], statement => {
        client.query_statement(statement, params~).collect()
      })
    },
    deadline?,
  )
}

///|
pub async fn Session::query_one(
  self : Session,
  sql : String,
  params~ : Array[&@client.ToSql] = [],
  deadline? : Deadline,
) -> @client.Row {
  self.run_operation(
    client => {
      cached_query(self.state, client, sql, [], statement => {
        client.query_statement(statement, params~).one()
      })
    },
    deadline?,
  )
}

///|
pub async fn Session::query_opt(
  self : Session,
  sql : String,
  params~ : Array[&@client.ToSql] = [],
  deadline? : Deadline,
) -> @client.Row? {
  self.run_operation(
    client => {
      cached_query(self.state, client, sql, [], statement => {
        client.query_statement(statement, params~).opt()
      })
    },
    deadline?,
  )
}

///|
pub async fn Session::execute(
  self : Session,
  sql : String,
  params~ : Array[&@client.ToSql] = [],
  deadline? : Deadline,
) -> UInt64 {
  self.run_operation(
    client => {
      cached_query(self.state, client, sql, [], statement => {
        client.execute_raw(statement, params~)
      })
    },
    deadline?,
  )
}

///|
pub async fn Session::query_typed_all(
  self : Session,
  sql : String,
  param_types : Array[@client.Type],
  params~ : Array[&@client.ToSql] = [],
  deadline? : Deadline,
) -> Array[@client.Row] {
  self.run_operation(
    client => {
      cached_query(self.state, client, sql, param_types, statement => {
        client.query_statement(statement, params~).collect()
      })
    },
    deadline?,
  )
}

///|
pub async fn Session::query_typed_one(
  self : Session,
  sql : String,
  param_types : Array[@client.Type],
  params~ : Array[&@client.ToSql] = [],
  deadline? : Deadline,
) -> @client.Row {
  self.run_operation(
    client => {
      cached_query(self.state, client, sql, param_types, statement => {
        client.query_statement(statement, params~).one()
      })
    },
    deadline?,
  )
}

///|
pub async fn Session::query_typed_opt(
  self : Session,
  sql : String,
  param_types : Array[@client.Type],
  params~ : Array[&@client.ToSql] = [],
  deadline? : Deadline,
) -> @client.Row? {
  self.run_operation(
    client => {
      cached_query(self.state, client, sql, param_types, statement => {
        client.query_statement(statement, params~).opt()
      })
    },
    deadline?,
  )
}

///|
pub async fn Session::execute_typed(
  self : Session,
  sql : String,
  param_types : Array[@client.Type],
  params~ : Array[&@client.ToSql] = [],
  deadline? : Deadline,
) -> UInt64 {
  self.run_operation(
    client => {
      cached_query(self.state, client, sql, param_types, statement => {
        client.execute_raw(statement, params~)
      })
    },
    deadline?,
  )
}

///|
pub async fn Session::batch_execute(
  self : Session,
  sql : String,
  deadline? : Deadline,
) -> Unit {
  self.run_operation(client => client.batch_execute(sql), deadline?)
}

///|
pub async fn Session::check_connection(
  self : Session,
  deadline? : Deadline,
) -> Unit {
  self.run_operation(client => client.check_connection(), deadline?)
}

///|
pub async fn Transaction::query_all(
  self : Transaction,
  sql : String,
  params~ : Array[&@client.ToSql] = [],
  deadline? : Deadline,
) -> Array[@client.Row] {
  self.run_operation(
    client => {
      cached_query(self.state, client, sql, [], statement => {
        client.query_statement(statement, params~).collect()
      })
    },
    deadline?,
  )
}

///|
pub async fn Transaction::query_one(
  self : Transaction,
  sql : String,
  params~ : Array[&@client.ToSql] = [],
  deadline? : Deadline,
) -> @client.Row {
  self.run_operation(
    client => {
      cached_query(self.state, client, sql, [], statement => {
        client.query_statement(statement, params~).one()
      })
    },
    deadline?,
  )
}

///|
pub async fn Transaction::query_opt(
  self : Transaction,
  sql : String,
  params~ : Array[&@client.ToSql] = [],
  deadline? : Deadline,
) -> @client.Row? {
  self.run_operation(
    client => {
      cached_query(self.state, client, sql, [], statement => {
        client.query_statement(statement, params~).opt()
      })
    },
    deadline?,
  )
}

///|
pub async fn Transaction::execute(
  self : Transaction,
  sql : String,
  params~ : Array[&@client.ToSql] = [],
  deadline? : Deadline,
) -> UInt64 {
  self.run_operation(
    client => {
      cached_query(self.state, client, sql, [], statement => {
        client.execute_raw(statement, params~)
      })
    },
    deadline?,
  )
}

///|
pub async fn Transaction::query_typed_all(
  self : Transaction,
  sql : String,
  param_types : Array[@client.Type],
  params~ : Array[&@client.ToSql] = [],
  deadline? : Deadline,
) -> Array[@client.Row] {
  self.run_operation(
    client => {
      cached_query(self.state, client, sql, param_types, statement => {
        client.query_statement(statement, params~).collect()
      })
    },
    deadline?,
  )
}

///|
pub async fn Transaction::query_typed_one(
  self : Transaction,
  sql : String,
  param_types : Array[@client.Type],
  params~ : Array[&@client.ToSql] = [],
  deadline? : Deadline,
) -> @client.Row {
  self.run_operation(
    client => {
      cached_query(self.state, client, sql, param_types, statement => {
        client.query_statement(statement, params~).one()
      })
    },
    deadline?,
  )
}

///|
pub async fn Transaction::query_typed_opt(
  self : Transaction,
  sql : String,
  param_types : Array[@client.Type],
  params~ : Array[&@client.ToSql] = [],
  deadline? : Deadline,
) -> @client.Row? {
  self.run_operation(
    client => {
      cached_query(self.state, client, sql, param_types, statement => {
        client.query_statement(statement, params~).opt()
      })
    },
    deadline?,
  )
}

///|
pub async fn Transaction::execute_typed(
  self : Transaction,
  sql : String,
  param_types : Array[@client.Type],
  params~ : Array[&@client.ToSql] = [],
  deadline? : Deadline,
) -> UInt64 {
  self.run_operation(
    client => {
      cached_query(self.state, client, sql, param_types, statement => {
        client.execute_raw(statement, params~)
      })
    },
    deadline?,
  )
}

///|
pub async fn Transaction::batch_execute(
  self : Transaction,
  sql : String,
  deadline? : Deadline,
) -> Unit {
  self.run_operation(client => client.batch_execute(sql), deadline?)
}

///|
pub async fn Transaction::check_connection(
  self : Transaction,
  deadline? : Deadline,
) -> Unit {
  self.run_operation(client => client.check_connection(), deadline?)
}
