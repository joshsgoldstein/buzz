//! Runtime SQL dialect detection: PostgreSQL vs CockroachDB.
//!
//! CockroachDB speaks the PostgreSQL wire protocol, so `sqlx` connects to both
//! unchanged and the vast majority of queries are identical. A few subsystems
//! genuinely diverge and must branch on the actual engine at runtime:
//!
//! - declarative range partitioning (`partition.rs`) — CockroachDB has none and
//!   range-distributes automatically, so partition management is a no-op there;
//! - read routing (`replica_fence.rs`) — CockroachDB serves lag-tolerant reads
//!   via follower reads (`AS OF SYSTEM TIME follower_read_timestamp()`) rather
//!   than a physically-replicated Aurora reader endpoint.
//!
//! Everything else is written to the intersection of the two engines (see the
//! migration set) and needs no branching. The dialect is probed once at startup
//! from `SELECT version()` and cached on [`crate::Db`].

use sqlx::PgPool;

/// The SQL engine behind the connection pool.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Dialect {
    Postgres,
    Cockroach,
}

impl Dialect {
    /// True when connected to CockroachDB.
    pub fn is_cockroach(self) -> bool {
        matches!(self, Dialect::Cockroach)
    }

    /// Classify a `version()` string. CockroachDB's begins with "CockroachDB"
    /// (e.g. "CockroachDB CCL v26.2.2 …"); PostgreSQL's begins with "PostgreSQL".
    pub fn from_version_string(version: &str) -> Dialect {
        if version.contains("CockroachDB") {
            Dialect::Cockroach
        } else {
            Dialect::Postgres
        }
    }
}

/// Probe the connected engine once. Any query failure is surfaced to the caller;
/// callers treat detection failure as fatal at startup (fail closed).
pub async fn detect(pool: &PgPool) -> Result<Dialect, sqlx::Error> {
    let version: String = sqlx::query_scalar("SELECT version()").fetch_one(pool).await?;
    Ok(Dialect::from_version_string(&version))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn classifies_cockroach_version() {
        assert_eq!(
            Dialect::from_version_string(
                "CockroachDB CCL v26.2.2 (aarch64-unknown-linux-gnu, built 2026/06/03)"
            ),
            Dialect::Cockroach
        );
        assert!(Dialect::from_version_string("CockroachDB CCL v26.2.2").is_cockroach());
    }

    #[test]
    fn classifies_postgres_version() {
        assert_eq!(
            Dialect::from_version_string(
                "PostgreSQL 17.2 (Debian 17.2-1) on aarch64-unknown-linux-gnu"
            ),
            Dialect::Postgres
        );
        assert!(!Dialect::from_version_string("PostgreSQL 17.2").is_cockroach());
    }
}
