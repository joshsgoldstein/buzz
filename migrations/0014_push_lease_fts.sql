-- NIP-PL kind:30350 contains endpoint-bearing NIP-44 ciphertext and is
-- author-only. Exclude it from full-text search without changing the search
-- policy of existing installations. In particular, migration 0008 deliberately
-- gives only empty/fresh databases the positive allowlist; populated databases
-- retain their prior expression until an operator runs the out-of-band rewrite.
--
-- PostgreSQL cannot alter a generated expression in place. Capture the current
-- expression before replacing the column, then wrap it with the new exclusion.
-- This preserves both the fresh-install allowlist and any brownfield/operator-
-- managed expression for every kind other than 30350.
-- Dual-compat: the original captured the live generated expression via
-- pg_get_expr and rebuilt it inside a DO block with EXECUTE format(...).
-- CockroachDB supports neither DDL inside a function/DO block. On a fresh
-- install (both engines) the expression coming out of migration 0008 is the
-- known allowlist, and kind 30350 is already excluded by that allowlist (it is
-- not in the allowed set), so the final expression is applied directly at the
-- top level. Brownfield PostgreSQL keeps its original migration untouched.
ALTER TABLE events DROP COLUMN search_tsv;
ALTER TABLE events ADD COLUMN search_tsv TSVECTOR GENERATED ALWAYS AS (
    CASE WHEN kind IN (0, 9, 40002, 45001, 45003) AND kind <> 30350
         THEN to_tsvector('simple', content)
         ELSE NULL::tsvector
    END
) STORED;
CREATE INDEX idx_events_search_tsv ON events USING GIN (search_tsv);
