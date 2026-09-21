// Explicitly preserve the dot-call methods that derived traits historically
// promoted for these public types.

///|
#deprecated
#doc(hidden)
pub extend DataRowBody with @debug.Debug::{to_repr}

///|
#deprecated
#doc(hidden)
pub extend DataRowBody with Eq::{not_equal, equal}

///|
#deprecated
#doc(hidden)
pub extend Header with @debug.Debug::{to_repr}
