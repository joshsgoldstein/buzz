-- Refresh ephemeral-channel expiry in the transaction that makes a
-- channel-scoped event durable. Deferring to COMMIT closes the stale-prefetch
-- race: the UPDATE sees a TTL transition committed while ingest was in flight,
-- or waits on its row lock and rechecks after it commits, without restoring a
-- separate hot-path transaction.
CREATE FUNCTION refresh_channel_ttl_after_event_insert() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    -- CockroachDB does not support PERFORM (even the locking form), so the
    -- FOR UPDATE lock acquisition below is written as SELECT ... INTO a throwaway
    -- variable. Valid on PostgreSQL too. Composite NEW field access is
    -- parenthesized so it parses on CockroachDB.
    _v integer;
BEGIN
    -- Kind 9007 creates the channel and initializes its deadline itself.
    IF (NEW).channel_id IS NOT NULL AND (NEW).kind <> 9007 THEN
        BEGIN
            -- Lock by identity before testing ttl_seconds. If a concurrent TTL
            -- transition is uncommitted, this waits and follows its updated row
            -- version instead of treating the old permanent version as final.
            SELECT 1 INTO _v FROM channels
            WHERE community_id = (NEW).community_id AND id = (NEW).channel_id
            FOR UPDATE;

            UPDATE channels
            -- Dual-compat: (n * interval '1 second') instead of
            -- make_interval(secs => n) (CRDB lacks `=>` named-arg call syntax).
            SET ttl_deadline = clock_timestamp() + (ttl_seconds * interval '1 second')
            WHERE community_id = (NEW).community_id
              AND id = (NEW).channel_id
              AND ttl_seconds IS NOT NULL
              AND archived_at IS NULL
              AND deleted_at IS NULL;
        EXCEPTION WHEN OTHERS THEN
            -- Preserve the existing best-effort contract: a TTL refresh failure
            -- must not reject an otherwise valid durable event.
            -- Dual-compat: SQLERRM dropped (CockroachDB resolves bare SQLERRM as
            -- a column here); the warning still fires with the ids.
            RAISE WARNING 'channel TTL refresh failed for community %, channel %',
                (NEW).community_id, (NEW).channel_id;
        END;
    END IF;
    RETURN NULL;
END
$$;

-- CockroachDB does not support CREATE CONSTRAINT TRIGGER / DEFERRABLE, so this
-- is a plain AFTER INSERT row trigger. The refresh runs at statement time
-- rather than at COMMIT; the advisory-lock repair in migration 0024 replaces
-- the function body and preserves the stale-prefetch proof without the deferred
-- semantics.
CREATE TRIGGER events_refresh_channel_ttl
AFTER INSERT ON events
FOR EACH ROW EXECUTE FUNCTION refresh_channel_ttl_after_event_insert();
