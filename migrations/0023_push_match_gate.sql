-- T1b push gate: skip push_match_queue enqueue entirely for communities with
-- no active, endpoint-enabled, unexpired push lease. In lease-less communities
-- (most of them) every durable message currently pays the full matcher cost
-- (enqueue + claim + lease scan + delete) to conclude "notify no one".
--
-- Correctness protocol (write-amp plan rev 3, [R2/R3]):
--   * The gate lives HERE, in the events trigger, so every durable producer is
--     covered — including internal paths that bypass live dispatch.
--   * Lost-wake race: a naive EXISTS check could read "no lease" while a lease
--     activation commits concurrently, silently dropping that user's wake with
--     no retry. Closed with a per-community advisory lock held to transaction
--     end: event inserts take the lock SHARED (concurrent with each other),
--     lease transitions that can make eligibility true take it EXCLUSIVE
--     (crates/buzz-db/src/push.rs: accept_lease_event and replace_lease).
--     The conflict forces a total order: either the event's check sees the
--     committed lease, or the activation strictly follows the event's commit —
--     in which case no lease existed when the event was accepted and no wake
--     was owed. The lease-activation backfill is product recovery coverage
--     only and is not part of this proof.
--   * Lock key domain 'buzz_push_gate:' is distinct from the audit lock
--     ('buzz_audit:') and both lease-address lock families.
-- Dual-compat advisory-lock emulation. CockroachDB v26.2.2 implements NO
-- advisory-lock builtins (neither pg_advisory_lock nor pg_advisory_xact_lock,
-- shared or exclusive) and has no hashtextextended. We emulate transaction-scoped
-- advisory locks with a keyed table: acquiring the lock inserts the key row (if
-- absent) then row-locks it, which releases at commit exactly like a
-- pg_advisory_xact_lock. FOR SHARE gives the shared variant (concurrent holders),
-- FOR UPDATE the exclusive variant — preserving the original shared/exclusive
-- split. Keys are md5-derived bigints (both engines). The relay's Rust exclusive
-- lock sites (push accept_lease/replace_lease, channel update, deletion worker)
-- must take xact_lock_exclusive() on the SAME table with the SAME key formula for
-- the guard to be complete; see the buzz-db port notes.
CREATE TABLE xact_advisory_locks (key INT8 PRIMARY KEY);

CREATE FUNCTION xact_lock_shared(k INT8) RETURNS INT8 LANGUAGE plpgsql AS $$
DECLARE _d INT8;
BEGIN
    INSERT INTO xact_advisory_locks (key) VALUES (k) ON CONFLICT DO NOTHING;
    SELECT 1 INTO _d FROM xact_advisory_locks WHERE key = k FOR SHARE;
    RETURN k;
END $$;

CREATE FUNCTION xact_lock_exclusive(k INT8) RETURNS INT8 LANGUAGE plpgsql AS $$
DECLARE _d INT8;
BEGIN
    INSERT INTO xact_advisory_locks (key) VALUES (k) ON CONFLICT DO NOTHING;
    SELECT 1 INTO _d FROM xact_advisory_locks WHERE key = k FOR UPDATE;
    RETURN k;
END $$;

CREATE OR REPLACE FUNCTION enqueue_push_match_job() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    -- CockroachDB does not support PERFORM, so the lock call is written as
    -- SELECT ... INTO a throwaway variable. Composite NEW access is parenthesized.
    _dummy bigint;
BEGIN
    -- Keep this allowlist identical to the relay's validated NIP-PL descriptor.
    IF (NEW).kind IN (7, 9, 1059, 40007, 46010) THEN
        -- Shared lock on the per-community push-gate key (concurrent with other
        -- event inserts; the lease-activation path takes it exclusive).
        SELECT xact_lock_shared(
            ('x' || substr(md5('buzz_push_gate:' || (NEW).community_id::text), 1, 16))::bit(64)::bigint
        ) INTO _dummy;
        IF EXISTS (
            SELECT 1 FROM push_leases
            WHERE community_id = (NEW).community_id
              AND active
              AND endpoint_enabled
              AND expires_at > EXTRACT(EPOCH FROM now())::bigint
        ) THEN
            INSERT INTO push_match_queue (community_id, event_id)
            VALUES ((NEW).community_id, (NEW).id)
            ON CONFLICT DO NOTHING;
        END IF;
    END IF;
    RETURN NEW;
END
$$;
