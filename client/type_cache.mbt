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
async fn cached_type(shared : Shared, oid : @proto.Oid) -> Type {
  match shared.types.get(oid) {
    Some(type_) => type_
    None => {
      // Cache misses are resolved once and written back so later row/parameter
      // decoding for the same OID stays local.
      let type_ = lookup_type(shared, oid)
      shared.types[oid] = type_
      type_
    }
  }
}

///|
/// Fetch rich metadata for a PostgreSQL type OID.
///
/// The driver first checks built-ins, then falls back to catalog queries. If
/// those fail or return no rows, it preserves the OID inside an `Unknown`
/// descriptor so later error messages remain informative.
async fn lookup_type(shared : Shared, oid : @proto.Oid) -> Type {
  match builtin_type(oid) {
    Some(type_) => type_
    None => {
      let rows = query_oid_catalog(shared, typeinfo_query, oid) catch {
        _ => []
      }
      // Catalog lookup is best-effort; falling back to `Unknown` preserves the
      // raw OID for later diagnostics without blocking query execution.
      if rows.is_empty() {
        return Type::unknown(oid, name="oid_\{oid.to_string()}")
      }
      let row = rows[0]
      let name : String = row.get(0)
      let typtype : String = row.get(1)
      let elem_oid : @proto.Oid = row.get(2)
      let range_subtype : @proto.Oid? = row.get(3)
      let base_oid : @proto.Oid = row.get(4)
      let relid : @proto.Oid = row.get(6)
      // Match PostgreSQL's richer type families first before falling back to a
      // plain scalar descriptor.
      let kind = if typtype == "e" {
        Kind::Enum(query_enum_labels(shared, oid))
      } else if typtype == "p" {
        Kind::Pseudo
      } else if base_oid != 0U {
        Kind::Domain(base_oid)
      } else if elem_oid != 0U {
        Kind::Array(elem_oid)
      } else if relid != 0U {
        Kind::Composite(query_composite_fields(shared, relid))
      } else {
        match range_subtype {
          Some(subtype) => Kind::Range(subtype)
          None => Kind::Simple
        }
      }
      { oid, name, kind }
    }
  }
}

///|
/// Run a catalog query that accepts a single OID parameter.
///
/// This helper builds a temporary `Client` facade around `Shared` so the type
/// cache can reuse the ordinary query path without special wiring.
async fn query_oid_catalog(
  shared : Shared,
  sql : String,
  oid : @proto.Oid,
) -> Array[Row] {
  let client : Client = { shared, }
  // Reuse the ordinary query pipeline so the type cache does not maintain its
  // own special-purpose protocol machinery.
  let params : Array[&ToSql] = [oid as &ToSql]
  let stream = client.query_typed(sql, [Type::oid_type()], params~)
  stream.collect()
}

///|
/// Fetch enum labels for one enum type OID.
async fn query_enum_labels(shared : Shared, oid : @proto.Oid) -> Array[String] {
  let rows = query_oid_catalog(shared, typeinfo_enum_query, oid) catch {
    _ => []
  }
  rows.map(row => row.get(0))
}

///|
/// Fetch field metadata for one composite type.
async fn query_composite_fields(
  shared : Shared,
  oid : @proto.Oid,
) -> Array[Field] {
  let rows = query_oid_catalog(shared, typeinfo_composite_query, oid) catch {
    _ => []
  }
  rows.map(row => { name: row.get(0), type_oid: row.get(1) })
}

///|
/// Parse parameter OIDs from PostgreSQL's `ParameterDescription`.
fn parse_parameter_oids(
  body : @backend.ParameterDescriptionBody,
) -> Array[@proto.Oid] raise {
  let types : Array[@proto.Oid] = []
  let params = body.parameters()
  for param = params.next() {
    match param {
      None => break types
      Some(oid) => {
        types.push(oid)
        continue params.next()
      }
    }
  }
}

///|
/// Resolve a parameter OID list into cached `Type` descriptors.
async fn resolve_parameter_types(
  shared : Shared,
  oids : Array[@proto.Oid],
) -> Array[Type] {
  let out : Array[Type] = []
  for oid in oids {
    out.push(cached_type(shared, oid))
  }
  out
}

///|
/// Replace placeholder column types with cached rich descriptors.
async fn resolve_columns(
  shared : Shared,
  columns : Array[Column],
) -> Array[Column] {
  let out : Array[Column] = []
  for column in columns {
    // Preserve every other row-description field and swap only the placeholder
    // type descriptor for its cached rich form.
    out.push({ ..column, type_: cached_type(shared, column.type_.oid) })
  }
  out
}
