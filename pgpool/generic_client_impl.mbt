///|
pub impl GenericClient for Session with fn query_all(
  self,
  sql,
  params?,
  deadline?,
) {
  self.query_all(sql, params=params.unwrap_or([]), deadline?)
}

///|
pub impl GenericClient for Transaction with fn query_all(
  self,
  sql,
  params?,
  deadline?,
) {
  self.query_all(sql, params=params.unwrap_or([]), deadline?)
}

///|
pub impl GenericClient for Pool with fn query_all(self, sql, params?, deadline?) {
  self.query_all(sql, params=params.unwrap_or([]), deadline?)
}

///|
pub impl GenericClient for Session with fn query_one(
  self,
  sql,
  params?,
  deadline?,
) {
  self.query_one(sql, params=params.unwrap_or([]), deadline?)
}

///|
pub impl GenericClient for Transaction with fn query_one(
  self,
  sql,
  params?,
  deadline?,
) {
  self.query_one(sql, params=params.unwrap_or([]), deadline?)
}

///|
pub impl GenericClient for Pool with fn query_one(self, sql, params?, deadline?) {
  self.query_one(sql, params=params.unwrap_or([]), deadline?)
}

///|
pub impl GenericClient for Session with fn query_opt(
  self,
  sql,
  params?,
  deadline?,
) {
  self.query_opt(sql, params=params.unwrap_or([]), deadline?)
}

///|
pub impl GenericClient for Transaction with fn query_opt(
  self,
  sql,
  params?,
  deadline?,
) {
  self.query_opt(sql, params=params.unwrap_or([]), deadline?)
}

///|
pub impl GenericClient for Pool with fn query_opt(self, sql, params?, deadline?) {
  self.query_opt(sql, params=params.unwrap_or([]), deadline?)
}

///|
pub impl GenericClient for Session with fn execute(
  self,
  sql,
  params?,
  deadline?,
) {
  self.execute(sql, params=params.unwrap_or([]), deadline?)
}

///|
pub impl GenericClient for Transaction with fn execute(
  self,
  sql,
  params?,
  deadline?,
) {
  self.execute(sql, params=params.unwrap_or([]), deadline?)
}

///|
pub impl GenericClient for Pool with fn execute(self, sql, params?, deadline?) {
  self.execute(sql, params=params.unwrap_or([]), deadline?)
}

///|
pub impl GenericClient for Session with fn query_typed_all(
  self,
  sql,
  param_types,
  params?,
  deadline?,
) {
  self.query_typed_all(sql, param_types, params=params.unwrap_or([]), deadline?)
}

///|
pub impl GenericClient for Transaction with fn query_typed_all(
  self,
  sql,
  param_types,
  params?,
  deadline?,
) {
  self.query_typed_all(sql, param_types, params=params.unwrap_or([]), deadline?)
}

///|
pub impl GenericClient for Pool with fn query_typed_all(
  self,
  sql,
  param_types,
  params?,
  deadline?,
) {
  self.query_typed_all(sql, param_types, params=params.unwrap_or([]), deadline?)
}

///|
pub impl GenericClient for Session with fn query_typed_one(
  self,
  sql,
  param_types,
  params?,
  deadline?,
) {
  self.query_typed_one(sql, param_types, params=params.unwrap_or([]), deadline?)
}

///|
pub impl GenericClient for Transaction with fn query_typed_one(
  self,
  sql,
  param_types,
  params?,
  deadline?,
) {
  self.query_typed_one(sql, param_types, params=params.unwrap_or([]), deadline?)
}

///|
pub impl GenericClient for Pool with fn query_typed_one(
  self,
  sql,
  param_types,
  params?,
  deadline?,
) {
  self.query_typed_one(sql, param_types, params=params.unwrap_or([]), deadline?)
}

///|
pub impl GenericClient for Session with fn query_typed_opt(
  self,
  sql,
  param_types,
  params?,
  deadline?,
) {
  self.query_typed_opt(sql, param_types, params=params.unwrap_or([]), deadline?)
}

///|
pub impl GenericClient for Transaction with fn query_typed_opt(
  self,
  sql,
  param_types,
  params?,
  deadline?,
) {
  self.query_typed_opt(sql, param_types, params=params.unwrap_or([]), deadline?)
}

///|
pub impl GenericClient for Pool with fn query_typed_opt(
  self,
  sql,
  param_types,
  params?,
  deadline?,
) {
  self.query_typed_opt(sql, param_types, params=params.unwrap_or([]), deadline?)
}

///|
pub impl GenericClient for Session with fn execute_typed(
  self,
  sql,
  param_types,
  params?,
  deadline?,
) {
  self.execute_typed(sql, param_types, params=params.unwrap_or([]), deadline?)
}

///|
pub impl GenericClient for Transaction with fn execute_typed(
  self,
  sql,
  param_types,
  params?,
  deadline?,
) {
  self.execute_typed(sql, param_types, params=params.unwrap_or([]), deadline?)
}

///|
pub impl GenericClient for Pool with fn execute_typed(
  self,
  sql,
  param_types,
  params?,
  deadline?,
) {
  self.execute_typed(sql, param_types, params=params.unwrap_or([]), deadline?)
}

///|
pub impl GenericClient for Session with fn batch_execute(self, sql, deadline?) {
  self.batch_execute(sql, deadline?)
}

///|
pub impl GenericClient for Transaction with fn batch_execute(
  self,
  sql,
  deadline?,
) {
  self.batch_execute(sql, deadline?)
}

///|
pub impl GenericClient for Pool with fn batch_execute(self, sql, deadline?) {
  self.batch_execute(sql, deadline?)
}

///|
pub impl GenericClient for Session with fn check_connection(self, deadline?) {
  self.check_connection(deadline?)
}

///|
pub impl GenericClient for Transaction with fn check_connection(self, deadline?) {
  self.check_connection(deadline?)
}

///|
pub impl GenericClient for Pool with fn check_connection(self, deadline?) {
  self.check_connection(deadline?)
}
