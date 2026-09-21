// Explicitly preserve the dot-call methods that derived traits historically
// promoted for these public types.

///|
#deprecated
#doc(hidden)
pub extend SslMode with @debug.Debug::{to_repr}

///|
#deprecated
#doc(hidden)
pub extend SslMode with Eq::{not_equal, equal}

///|
#deprecated
#doc(hidden)
pub extend ChannelBinding with @debug.Debug::{to_repr}

///|
#deprecated
#doc(hidden)
pub extend ChannelBinding with Eq::{not_equal, equal}

///|
#deprecated
#doc(hidden)
pub extend Config with @debug.Debug::{to_repr}

///|
#deprecated
#doc(hidden)
pub extend Config with Eq::{not_equal, equal}

///|
#deprecated
#doc(hidden)
pub extend Notification with @debug.Debug::{to_repr}

///|
#deprecated
#doc(hidden)
pub extend Notification with Eq::{not_equal, equal}

///|
#deprecated
#doc(hidden)
pub extend AsyncMessage with @debug.Debug::{to_repr}

///|
#deprecated
#doc(hidden)
pub extend AsyncMessage with Eq::{not_equal, equal}

///|
#deprecated
#doc(hidden)
pub extend Kind with @debug.Debug::{to_repr}

///|
#deprecated
#doc(hidden)
pub extend Kind with Eq::{not_equal, equal}

///|
#deprecated
#doc(hidden)
pub extend Field with @debug.Debug::{to_repr}

///|
#deprecated
#doc(hidden)
pub extend Field with Eq::{not_equal, equal}

///|
#deprecated
#doc(hidden)
pub extend Type with @debug.Debug::{to_repr}

///|
#deprecated
#doc(hidden)
pub extend Type with Eq::{not_equal, equal}

///|
#deprecated
#doc(hidden)
pub extend DatabaseError with @debug.Debug::{to_repr}

///|
#deprecated
#doc(hidden)
pub extend DatabaseError with Eq::{not_equal, equal}

///|
#deprecated
#doc(hidden)
pub extend WrongTypeError with @debug.Debug::{to_repr}

///|
#deprecated
#doc(hidden)
pub extend WrongTypeError with Eq::{not_equal, equal}

///|
#deprecated
#doc(hidden)
pub extend ClientError with @debug.Debug::{to_repr}

///|
#deprecated
#doc(hidden)
pub extend ClientError with Eq::{not_equal, equal}

///|
#deprecated
#doc(hidden)
pub extend QuerySummary with @debug.Debug::{to_repr}

///|
#deprecated
#doc(hidden)
pub extend QuerySummary with Eq::{not_equal, equal}

///|
#deprecated
#doc(hidden)
pub extend Column with @debug.Debug::{to_repr}

///|
#deprecated
#doc(hidden)
pub extend Column with Eq::{not_equal, equal}

///|
#deprecated
#doc(hidden)
pub extend Row with @debug.Debug::{to_repr}

///|
#deprecated
#doc(hidden)
pub extend Row with Eq::{not_equal, equal}

///|
#deprecated
#doc(hidden)
pub extend SimpleQueryRow with @debug.Debug::{to_repr}

///|
#deprecated
#doc(hidden)
pub extend SimpleQueryRow with Eq::{not_equal, equal}

///|
#deprecated
#doc(hidden)
pub extend SimpleQueryMessage with @debug.Debug::{to_repr}

///|
#deprecated
#doc(hidden)
pub extend SimpleQueryMessage with Eq::{not_equal, equal}

///|
#deprecated
#doc(hidden)
pub extend WireFormat with @debug.Debug::{to_repr}

///|
#deprecated
#doc(hidden)
pub extend WireFormat with Eq::{not_equal, equal}

///|
#deprecated
#doc(hidden)
pub extend TransactionOptions with @debug.Debug::{to_repr}

///|
#deprecated
#doc(hidden)
pub extend TransactionOptions with Eq::{not_equal, equal}
