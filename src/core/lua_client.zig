//! The client library, as bytes.
//!
//! `src/core/lua/hexe.lua` is what another program requires to talk to a running
//! session. It is embedded rather than read from disk so the copy a consumer
//! gets is the one this build speaks, and so a client works on a machine with
//! no hexe source tree on it.

/// Printed by `hexe lua-api`.
pub const SOURCE = @embedFile("lua/hexe.lua");
