//! Server persistence building blocks. The v1 executable does not use the v2
//! database; HA coordination must explicitly supply validated commit decisions.
pub mod storage;
pub mod ha;
