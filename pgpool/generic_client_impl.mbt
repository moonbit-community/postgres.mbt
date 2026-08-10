// GenericClient implementations for pooled handles.

///|
/// Pools implement the shared high-level query trait using automatic checkout.
pub impl GenericClient for Pool with fn query_all(self, sql, params?) {
  self.query_all(sql, params=params.unwrap_or([]))
}

///|
/// Pools implement the shared high-level query trait using automatic checkout.
pub impl GenericClient for Pool with fn query_one(self, sql, params?) {
  self.query_one(sql, params=params.unwrap_or([]))
}

///|
/// Pools implement the shared high-level query trait using automatic checkout.
pub impl GenericClient for Pool with fn query_opt(self, sql, params?) {
  self.query_opt(sql, params=params.unwrap_or([]))
}

///|
/// Pools implement the shared high-level query trait using automatic checkout.
pub impl GenericClient for Pool with fn query_typed_all(
  self,
  sql,
  param_types,
  params?,
) {
  self.query_typed_all(sql, param_types, params=params.unwrap_or([]))
}

///|
/// Pools implement the shared high-level query trait using automatic checkout.
pub impl GenericClient for Pool with fn execute(self, sql, params?) {
  self.execute(sql, params=params.unwrap_or([]))
}

///|
/// Pools implement the shared high-level query trait using automatic checkout.
pub impl GenericClient for Pool with fn batch_execute(self, sql) {
  self.batch_execute(sql)
}

///|
/// Pools implement the shared high-level query trait using automatic checkout.
pub impl GenericClient for Pool with fn check_connection(self) {
  self.check_connection()
}

///|
/// Pooled clients implement the shared high-level query trait.
pub impl GenericClient for Session with fn query_all(self, sql, params?) {
  self.query_all(sql, params=params.unwrap_or([]))
}

///|
/// Pooled clients implement the shared high-level query trait.
pub impl GenericClient for Session with fn query_one(self, sql, params?) {
  self.query_one(sql, params=params.unwrap_or([]))
}

///|
/// Pooled clients implement the shared high-level query trait.
pub impl GenericClient for Session with fn query_opt(self, sql, params?) {
  self.query_opt(sql, params=params.unwrap_or([]))
}

///|
/// Pooled clients implement the shared high-level query trait.
pub impl GenericClient for Session with fn query_typed_all(
  self,
  sql,
  param_types,
  params?,
) {
  self.query_typed_all(sql, param_types, params=params.unwrap_or([]))
}

///|
/// Pooled clients implement the shared high-level query trait.
pub impl GenericClient for Session with fn execute(self, sql, params?) {
  self.execute(sql, params=params.unwrap_or([]))
}

///|
/// Pooled clients implement the shared high-level query trait.
pub impl GenericClient for Session with fn batch_execute(self, sql) {
  self.batch_execute(sql)
}

///|
/// Pooled clients implement the shared high-level query trait.
pub impl GenericClient for Session with fn check_connection(self) {
  self.check_connection()
}

///|
/// Pooled transactions implement the shared high-level query trait.
pub impl GenericClient for Transaction with fn query_all(self, sql, params?) {
  self.query_all(sql, params=params.unwrap_or([]))
}

///|
/// Pooled transactions implement the shared high-level query trait.
pub impl GenericClient for Transaction with fn query_one(self, sql, params?) {
  self.query_one(sql, params=params.unwrap_or([]))
}

///|
/// Pooled transactions implement the shared high-level query trait.
pub impl GenericClient for Transaction with fn query_opt(self, sql, params?) {
  self.query_opt(sql, params=params.unwrap_or([]))
}

///|
/// Pooled transactions implement the shared high-level query trait.
pub impl GenericClient for Transaction with fn query_typed_all(
  self,
  sql,
  param_types,
  params?,
) {
  self.query_typed_all(sql, param_types, params=params.unwrap_or([]))
}

///|
/// Pooled transactions implement the shared high-level query trait.
pub impl GenericClient for Transaction with fn execute(self, sql, params?) {
  self.execute(sql, params=params.unwrap_or([]))
}

///|
/// Pooled transactions implement the shared high-level query trait.
pub impl GenericClient for Transaction with fn batch_execute(self, sql) {
  self.batch_execute(sql)
}

///|
/// Pooled transactions implement the shared high-level query trait.
pub impl GenericClient for Transaction with fn check_connection(self) {
  self.check_connection()
}
