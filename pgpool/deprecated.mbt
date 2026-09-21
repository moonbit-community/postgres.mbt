// Explicitly preserve the dot-call methods that derived traits historically
// promoted for these public types.

///|
#deprecated
#doc(hidden)
pub extend QueueMode with @debug.Debug::{to_repr}

///|
#deprecated
#doc(hidden)
pub extend QueueMode with Eq::{not_equal, equal}

///|
#deprecated
#doc(hidden)
pub extend TimeoutKind with @debug.Debug::{to_repr}

///|
#deprecated
#doc(hidden)
pub extend TimeoutKind with Eq::{not_equal, equal}

///|
#deprecated
#doc(hidden)
pub extend IsolationLevel with @debug.Debug::{to_repr}

///|
#deprecated
#doc(hidden)
pub extend IsolationLevel with Eq::{not_equal, equal}

///|
#deprecated
#doc(hidden)
pub extend TransactionOptions with @debug.Debug::{to_repr}

///|
#deprecated
#doc(hidden)
pub extend TransactionOptions with Eq::{not_equal, equal}

///|
#deprecated
#doc(hidden)
pub extend Timeouts with @debug.Debug::{to_repr}

///|
#deprecated
#doc(hidden)
pub extend Timeouts with Eq::{not_equal, equal}

///|
#deprecated
#doc(hidden)
pub extend RecyclingMethod with @debug.Debug::{to_repr}

///|
#deprecated
#doc(hidden)
pub extend RecyclingMethod with Eq::{not_equal, equal}

///|
#deprecated
#doc(hidden)
pub extend PoolConfig with @debug.Debug::{to_repr}

///|
#deprecated
#doc(hidden)
pub extend PoolConfig with Eq::{not_equal, equal}

///|
#deprecated
#doc(hidden)
pub extend ConfigError with @debug.Debug::{to_repr}

///|
#deprecated
#doc(hidden)
pub extend ConfigError with Eq::{not_equal, equal}

///|
#deprecated
#doc(hidden)
pub extend TargetSessionAttrs with @debug.Debug::{to_repr}

///|
#deprecated
#doc(hidden)
pub extend TargetSessionAttrs with Eq::{not_equal, equal}

///|
#deprecated
#doc(hidden)
pub extend LoadBalanceHosts with @debug.Debug::{to_repr}

///|
#deprecated
#doc(hidden)
pub extend LoadBalanceHosts with Eq::{not_equal, equal}

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
pub extend Status with @debug.Debug::{to_repr}

///|
#deprecated
#doc(hidden)
pub extend Status with Eq::{not_equal, equal}

///|
#deprecated
#doc(hidden)
pub extend PoolError with @debug.Debug::{to_repr}

///|
#deprecated
#doc(hidden)
pub extend PoolError with Eq::{not_equal, equal}
