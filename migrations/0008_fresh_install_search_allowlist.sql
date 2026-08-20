-- Give new, empty installations the positive FTS allowlist without rewriting
-- populated databases during relay startup. Existing installations keep their
-- current search_tsv expression until an operator runs the sized out-of-band
-- maintenance script in scripts/maintenance/nip_rs_search_allowlist.sql.
--
-- Dual-compat: the original wrapped the emptiness-gated ALTER in a DO block and
-- took an explicit table lock. CockroachDB supports neither DDL inside a
-- function/DO block nor the SHARE ROW EXCLUSIVE lock-mode syntax. This edited
-- migration set only runs on fresh installs (both engines), where events is
-- always empty, so the emptiness guard is unconditionally true and the ALTER is
-- applied at the top level. Brownfield PostgreSQL keeps its original migration
-- history (with the DO-block guard) untouched.
ALTER TABLE events DROP COLUMN search_tsv;
ALTER TABLE events ADD COLUMN search_tsv TSVECTOR GENERATED ALWAYS AS (
    CASE WHEN kind IN (0, 9, 40002, 45001, 45003)
         THEN to_tsvector('simple', content)
         ELSE NULL::tsvector
    END
) STORED;
CREATE INDEX idx_events_search_tsv ON events USING GIN (search_tsv);
