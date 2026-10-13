// Expose derived trait methods through dot-call syntax for these public types.

///|
#deprecated
#doc(hidden)
pub extend ProtocolError with @debug.Debug::{to_repr}

///|
#deprecated
#doc(hidden)
pub extend ProtocolError with Eq::{not_equal, equal}
