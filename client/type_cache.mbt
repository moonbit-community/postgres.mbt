// Lazy PostgreSQL type introspection backed by system catalog queries.

///|
/// Query that retrieves the high-level shape of one PostgreSQL type OID.
let typeinfo_query = "select t.typname::text, t.typtype::text, t.typelem::oid, r.rngsubtype::oid, t.typbasetype::oid, n.nspname::text, t.typrelid::oid from pg_catalog.pg_type t left join pg_catalog.pg_range r on r.rngtypid = t.oid inner join pg_catalog.pg_namespace n on t.typnamespace = n.oid where t.oid = $1"

///|
/// Query that retrieves enum labels for one PostgreSQL enum type.
let typeinfo_enum_query = "select enumlabel::text from pg_catalog.pg_enum where enumtypid = $1 order by enumsortorder"

///|
/// Query that retrieves visible composite fields for one relation-backed type.
let typeinfo_composite_query = "select attname::text, atttypid::oid from pg_catalog.pg_attribute where attrelid = $1 and not attisdropped and attnum > 0 order by attnum"

///|
/// Return a cached `Type`, querying PostgreSQL catalogs only on cache misses.
async fn cached_type(context : OpContext, oid : @proto.Oid) -> Type {
  cached_type_recursive(context, oid, {})
}

///|
/// Only completed descriptors enter the cache. Active OIDs belong to this
/// resolution path, so repeated sibling references can reuse completed types.
async fn cached_type_recursive(
  context : OpContext,
  oid : @proto.Oid,
  active : Map[@proto.Oid, Unit],
) -> Type {
  if active.contains(oid) {
    raise ClientError::UnsupportedRecursiveType(oid)
  }
  if context.client.shared.types.get(oid) is Some(type_) {
    return type_
  }
  active[oid] = ()
  defer active.remove(oid)
  let type_ = lookup_type(context, oid, active)
  context.client.shared.types[oid] = type_
  type_
}

///|
/// Fetch rich metadata for a PostgreSQL type OID.
///
/// The driver first checks built-ins, then falls back to catalog queries. If
/// a catalog query returns a PostgreSQL error or no rows, it preserves the OID
/// inside an `Unknown` descriptor so later error messages remain informative.
async fn lookup_type(
  context : OpContext,
  oid : @proto.Oid,
  active : Map[@proto.Oid, Unit],
) -> Type {
  if builtin_type(oid) is Some(type_) {
    type_
  } else {
    let rows = query_oid_catalog(context, typeinfo_query, oid) catch {
      ClientError::Database(_) => []
      err => raise err
    }
    // A PostgreSQL catalog error is recoverable here. Transport and protocol
    // errors still propagate; neither leaves a trustworthy type descriptor.
    if rows.is_empty() {
      return Type::unknown(oid, name="oid_\{oid.to_string()}")
    }
    let row = rows[0]
    let name : String = row.get(0)
    let typtype : String = row.get(1)
    let elem_oid : @proto.Oid = row.get(2)
    let range_subtype : @proto.Oid? = row.get(3)
    let base_oid : @proto.Oid = row.get(4)
    let schema : String = row.get(5)
    let relid : @proto.Oid = row.get(6)
    // Match PostgreSQL's richer type families first before falling back to a
    // plain scalar descriptor.
    // Catalog helpers return fresh arrays. Once cached as views, their
    // backing storage has no mutable alias left in the client.
    let kind = if typtype == "e" {
      let labels = query_enum_labels(context, oid)
      Kind::Enum(labels[:])
    } else if typtype == "p" {
      Pseudo
    } else if base_oid != 0U {
      Domain(cached_type_recursive(context, base_oid, active))
    } else if elem_oid != 0U {
      Array(cached_type_recursive(context, elem_oid, active))
    } else if relid != 0U {
      let fields = query_composite_fields(context, relid, active)
      Composite(fields[:])
    } else if range_subtype is Some(subtype) {
      Range(cached_type_recursive(context, subtype, active))
    } else {
      Simple
    }
    { oid, name, schema: Some(schema), kind, }
  }
}

///|
/// Run a catalog query that accepts a single OID parameter.
///
/// The query uses its parent's operation context so it does not reacquire the
/// same single-flight gate.
async fn query_oid_catalog(
  context : OpContext,
  sql : String,
  oid : @proto.Oid,
) -> Array[Row] {
  let params : Array[&ToSql] = [oid]
  let stream = context.query_typed(sql, [Type::oid_type()], params)
  stream.collect()
}

///|
/// Fetch enum labels for one enum type OID.
async fn query_enum_labels(
  context : OpContext,
  oid : @proto.Oid,
) -> Array[String] {
  let rows = query_oid_catalog(context, typeinfo_enum_query, oid) catch {
    ClientError::Database(_) => []
    err => raise err
  }
  rows.map(row => row.get(0))
}

///|
/// Fetch field metadata for one composite type.
async fn query_composite_fields(
  context : OpContext,
  oid : @proto.Oid,
  active : Map[@proto.Oid, Unit],
) -> Array[Field] {
  let rows = query_oid_catalog(context, typeinfo_composite_query, oid) catch {
    ClientError::Database(_) => []
    err => raise err
  }
  let fields : Array[Field] = []
  for row in rows {
    let name : String = row.get(0)
    let type_ = cached_type_recursive(context, row.get(1), active)
    fields.push({ name, type_, })
  }
  fields
}

///|
/// Parse parameter OIDs from PostgreSQL's `ParameterDescription`.
fn parse_parameter_oids(
  body : @backend.ParameterDescriptionBody,
) -> Array[@proto.Oid] raise {
  let types : Array[@proto.Oid] = []
  let params = body.parameters()
  for param = params.next() {
    if param is Some(oid) {
      types.push(oid)
      continue params.next()
    } else {
      break types
    }
  }
}

///|
/// Resolve a parameter OID list into cached `Type` descriptors.
async fn resolve_parameter_types(
  context : OpContext,
  oids : Array[@proto.Oid],
) -> Array[Type] {
  let out : Array[Type] = []
  for oid in oids {
    out.push(cached_type(context, oid))
  }
  out
}

///|
/// Replace placeholder column types with cached rich descriptors.
async fn resolve_columns(
  context : OpContext,
  columns : Array[Column],
) -> Array[Column] {
  let out : Array[Column] = []
  for column in columns {
    // Preserve every other row-description field and swap only the placeholder
    // type descriptor for its cached rich form.
    out.push({ ..column, type_: cached_type(context, column.type_.oid), })
  }
  out
}
