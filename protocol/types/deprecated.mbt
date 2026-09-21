// Explicitly preserve the dot-call methods that derived traits historically
// promoted for these public types.

///|
#deprecated
#doc(hidden)
pub extend ArrayDimension with @debug.Debug::{to_repr}

///|
#deprecated
#doc(hidden)
pub extend ArrayDimension with Eq::{not_equal, equal}

///|
#deprecated
#doc(hidden)
pub extend Point with @debug.Debug::{to_repr}

///|
#deprecated
#doc(hidden)
pub extend Point with Eq::{not_equal, equal}

///|
#deprecated
#doc(hidden)
pub extend Box with @debug.Debug::{to_repr}

///|
#deprecated
#doc(hidden)
pub extend Box with Eq::{not_equal, equal}
