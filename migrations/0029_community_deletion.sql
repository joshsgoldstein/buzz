-- Durable, CLI-only whole-community deletion control plane.
--
-- The community row is never removed: it becomes the permanent name tombstone.
-- All destructive progress is lease/fence/checkpoint guarded and every existing
-- community-scoped table receives the same database-enforced write fence.
-- This migration intentionally remains one atomic catalog change so a failed
-- deployment cannot expose only a subset of the universal fences. CREATE
-- TRIGGER takes SHARE ROW EXCLUSIVE on each target; fail quickly rather than
-- queueing behind long transactions. See the chart deletion rollout runbook.
SET LOCAL lock_timeout = '5s';

ALTER TABLE communities
    ADD COLUMN deletion_state TEXT NOT NULL DEFAULT 'active'
        CHECK (deletion_state IN ('active', 'quiescing', 'fenced', 'tombstone')),
    ADD COLUMN deletion_fence_generation BIGINT NOT NULL DEFAULT 0
        CHECK (deletion_fence_generation >= 0),
    ADD COLUMN deleted_at TIMESTAMPTZ;

CREATE TABLE community_deletion_requests (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    community_id UUID NOT NULL UNIQUE REFERENCES communities(id),
    community_host TEXT NOT NULL,
    -- Name the stage check explicitly. Migration 0030 drops it by this exact
    -- name to widen the allowed set; PostgreSQL would auto-name an inline column
    -- check `community_deletion_requests_stage_check`, but CockroachDB auto-names
    -- it differently (e.g. `check_stage`), which would make 0030's by-name DROP
    -- CONSTRAINT fail on CRDB. Naming it here keeps the DROP dual-compatible.
    -- Valid on PostgreSQL too (this is the name PostgreSQL would have chosen).
    stage TEXT NOT NULL DEFAULT 'submitted'
        CONSTRAINT community_deletion_requests_stage_check CHECK (stage IN (
        'submitted', 'inventoried', 'approved', 'fenced', 'drained',
        'bindings_removed', 'postgres_purged', 'cache_purged',
        'logically_verified', 'retention_pending'
    )),
    requested_by TEXT NOT NULL,
    reason TEXT,
    schema_manifest JSONB,
    storage_manifest JSONB,
    destructive_storage_manifest JSONB,
    destructive_storage_frozen_at TIMESTAMPTZ,
    inventory_manifest JSONB,
    inventory_digest BYTEA CHECK (inventory_digest IS NULL OR length(inventory_digest) = 32),
    inventory_frozen_at TIMESTAMPTZ,
    fence_generation BIGINT CHECK (fence_generation IS NULL OR fence_generation > 0),
    lease_owner TEXT,
    lease_generation BIGINT NOT NULL DEFAULT 0 CHECK (lease_generation >= 0),
    lease_until TIMESTAMPTZ,
    attempts INTEGER NOT NULL DEFAULT 0 CHECK (attempts >= 0),
    retry_count INTEGER NOT NULL DEFAULT 0 CHECK (retry_count >= 0),
    retry_stage TEXT CHECK (retry_stage IS NULL OR retry_stage IN (
        'approved', 'fenced', 'drained', 'bindings_removed',
        'postgres_purged', 'cache_purged', 'logically_verified'
    )),
    next_attempt_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    last_error TEXT,
    last_error_at TIMESTAMPTZ,
    blocked_at TIMESTAMPTZ,
    blocked_reason TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    completed_at TIMESTAMPTZ,
    CHECK ((blocked_at IS NULL) = (blocked_reason IS NULL)),
    CHECK ((inventory_frozen_at IS NULL) = (inventory_digest IS NULL)),
    UNIQUE (id, community_id, inventory_digest)
);
CREATE INDEX community_deletion_requests_runnable
    ON community_deletion_requests (next_attempt_at, created_at)
    WHERE blocked_at IS NULL
      AND stage IN ('approved', 'fenced', 'drained', 'bindings_removed',
                    'postgres_purged', 'cache_purged', 'logically_verified');
CREATE INDEX community_deletion_requests_lease
    ON community_deletion_requests (lease_until)
    WHERE lease_owner IS NOT NULL;

CREATE TABLE community_deletion_approvals (
    request_id UUID PRIMARY KEY,
    community_id UUID NOT NULL,
    inventory_digest BYTEA NOT NULL CHECK (length(inventory_digest) = 32),
    approved_by TEXT NOT NULL,
    note TEXT,
    approved_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    FOREIGN KEY (request_id, community_id, inventory_digest)
        REFERENCES community_deletion_requests(id, community_id, inventory_digest)
        ON DELETE RESTRICT
);

-- The approval identity is only meaningful while its frozen target and
-- inventory remain unchanged. Make those facts irreversible in the database,
-- not merely conventions in the worker.
CREATE FUNCTION prevent_community_deletion_request_retargeting()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    -- Composite OLD/NEW field access is parenthesized as (OLD).x / (NEW).x so it
    -- parses on CockroachDB (bare OLD.x is read there as a column reference).
    -- Valid on PostgreSQL too.
    IF (NEW).community_id IS DISTINCT FROM (OLD).community_id
        OR (NEW).community_host IS DISTINCT FROM (OLD).community_host
    THEN
        RAISE EXCEPTION 'community deletion target identity is immutable'
            USING ERRCODE = 'integrity_constraint_violation';
    END IF;
    IF (OLD).inventory_frozen_at IS NOT NULL AND (
        (NEW).schema_manifest IS DISTINCT FROM (OLD).schema_manifest
        OR (NEW).storage_manifest IS DISTINCT FROM (OLD).storage_manifest
        OR (NEW).inventory_manifest IS DISTINCT FROM (OLD).inventory_manifest
        OR (NEW).inventory_digest IS DISTINCT FROM (OLD).inventory_digest
        OR (NEW).inventory_frozen_at IS DISTINCT FROM (OLD).inventory_frozen_at
    ) THEN
        RAISE EXCEPTION 'frozen community deletion inventory is immutable'
            USING ERRCODE = 'integrity_constraint_violation';
    END IF;
    IF (OLD).destructive_storage_frozen_at IS NOT NULL AND (
        (NEW).destructive_storage_manifest IS DISTINCT FROM (OLD).destructive_storage_manifest
        OR (NEW).destructive_storage_frozen_at IS DISTINCT FROM (OLD).destructive_storage_frozen_at
    ) THEN
        RAISE EXCEPTION 'frozen destructive storage manifest is immutable'
            USING ERRCODE = 'integrity_constraint_violation';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER community_deletion_request_retargeting_guard
BEFORE UPDATE ON community_deletion_requests
FOR EACH ROW
EXECUTE FUNCTION prevent_community_deletion_request_retargeting();

CREATE FUNCTION prevent_community_deletion_approval_removal()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    RAISE EXCEPTION 'community deletion approval evidence is immutable'
        USING ERRCODE = 'integrity_constraint_violation';
END;
$$;

CREATE TRIGGER community_deletion_approval_removal_guard
BEFORE UPDATE OR DELETE ON community_deletion_approvals
FOR EACH ROW
EXECUTE FUNCTION prevent_community_deletion_approval_removal();

CREATE TABLE community_deletion_checkpoints (
    request_id UUID NOT NULL REFERENCES community_deletion_requests(id) ON DELETE RESTRICT,
    sequence BIGINT GENERATED ALWAYS AS IDENTITY,
    stage TEXT NOT NULL,
    unit_key TEXT NOT NULL,
    status TEXT NOT NULL CHECK (status IN ('started', 'completed', 'failed')),
    lease_generation BIGINT NOT NULL CHECK (lease_generation > 0),
    attempts INTEGER NOT NULL DEFAULT 1 CHECK (attempts > 0),
    detail JSONB NOT NULL DEFAULT '{}'::jsonb,
    error TEXT,
    started_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    completed_at TIMESTAMPTZ,
    PRIMARY KEY (request_id, sequence),
    UNIQUE (request_id, stage, unit_key),
    CHECK ((status = 'completed') = (completed_at IS NOT NULL)),
    CHECK ((status = 'failed') = (error IS NOT NULL))
);

-- Frozen destructive key list, chunked out of the request row so a large
-- tenant (100k-1M objects) never materializes as one multi-hundred-MB JSONB
-- value. Rows are written once in the fenced stage, stamped `deleted_at` as
-- the executor confirms each chunk removed, and dropped at logical
-- verification. The request row keeps only per-prefix count/bytes/digest
-- summaries; the chunk stream must hash to those frozen digests.
CREATE TABLE community_deletion_manifest_keys (
    request_id UUID NOT NULL REFERENCES community_deletion_requests(id) ON DELETE CASCADE,
    chunk_no BIGINT NOT NULL CHECK (chunk_no >= 0),
    prefix TEXT NOT NULL,
    keys JSONB NOT NULL,
    deleted_at TIMESTAMPTZ,
    PRIMARY KEY (request_id, chunk_no)
);

-- Chunk content is immutable once written; the only permitted update is the
-- one-way deleted_at stamp. New chunks are permitted only while the request is
-- fenced and its destructive manifest remains unfrozen. Removal is permitted
-- only while the destructive manifest has not yet frozen (a retried partial
-- freeze rewrites its chunks) or once the request has passed logical
-- verification (terminal cleanup).
CREATE FUNCTION protect_community_deletion_manifest_keys()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    frozen_at TIMESTAMPTZ;
    request_stage TEXT;
BEGIN
    -- Composite OLD/NEW field access is parenthesized as (OLD).x / (NEW).x so it
    -- parses on CockroachDB. The parent request's stage column is NOT NULL, so
    -- "a row was found" is tested as `request_stage IS NOT NULL` rather than the
    -- bare FOUND flag, which CockroachDB resolves as a column reference. Both
    -- rewrites are valid on PostgreSQL too.
    IF TG_OP = 'UPDATE' THEN
        IF (NEW).request_id IS DISTINCT FROM (OLD).request_id
            OR (NEW).chunk_no IS DISTINCT FROM (OLD).chunk_no
            OR (NEW).prefix IS DISTINCT FROM (OLD).prefix
            OR (NEW).keys IS DISTINCT FROM (OLD).keys
            OR (OLD).deleted_at IS NOT NULL
        THEN
            RAISE EXCEPTION 'community deletion manifest key chunks are immutable'
                USING ERRCODE = 'integrity_constraint_violation';
        END IF;
        RETURN NEW;
    END IF;
    SELECT destructive_storage_frozen_at, stage
      INTO frozen_at, request_stage
      FROM community_deletion_requests
     WHERE id = CASE WHEN TG_OP = 'INSERT' THEN (NEW).request_id ELSE (OLD).request_id END
     FOR UPDATE;
    IF TG_OP = 'INSERT' THEN
        IF request_stage IS NOT NULL AND frozen_at IS NULL AND request_stage = 'fenced' THEN
            RETURN NEW;
        END IF;
        RAISE EXCEPTION 'community deletion manifest key chunks require an unfrozen fenced request'
            USING ERRCODE = 'integrity_constraint_violation';
    END IF;
    IF request_stage IS NULL
        OR frozen_at IS NULL
        OR request_stage IN ('logically_verified', 'retention_pending')
    THEN
        RETURN OLD;
    END IF;
    RAISE EXCEPTION 'community deletion manifest key chunks cannot be removed mid-execution'
        USING ERRCODE = 'integrity_constraint_violation';
END;
$$;

CREATE TRIGGER community_deletion_manifest_keys_guard
BEFORE INSERT OR UPDATE OR DELETE ON community_deletion_manifest_keys
FOR EACH ROW
EXECUTE FUNCTION protect_community_deletion_manifest_keys();

-- Fleet-wide object-store taxonomy sweep evidence. This is an independent
-- observability record: community deletion inventories only the target's owned
-- prefixes and does not gate submission or execution on sweep state.
CREATE TABLE storage_taxonomy_sweeps (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    started_at TIMESTAMPTZ NOT NULL,
    completed_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    listed_objects BIGINT NOT NULL CHECK (listed_objects >= 0),
    unknown_object_count BIGINT NOT NULL CHECK (unknown_object_count >= 0),
    unknown_key_sample JSONB NOT NULL DEFAULT '[]'::jsonb,
    object_cap BIGINT NOT NULL CHECK (object_cap > 0),
    CHECK (completed_at >= started_at)
);
CREATE INDEX storage_taxonomy_sweeps_latest
    ON storage_taxonomy_sweeps (completed_at DESC);

CREATE TABLE community_serving_write_leases (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    community_id UUID NOT NULL REFERENCES communities(id),
    operation TEXT NOT NULL,
    owner TEXT NOT NULL,
    generation BIGINT NOT NULL DEFAULT 1 CHECK (generation > 0),
    -- Community fence generation observed when this lease was acquired.
    fence_generation BIGINT NOT NULL CHECK (fence_generation >= 0),
    lease_until TIMESTAMPTZ NOT NULL,
    heartbeat_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX community_serving_write_leases_active
    ON community_serving_write_leases (community_id, lease_until);

CREATE TABLE community_deletion_executor_heartbeats (
    executor_id TEXT PRIMARY KEY,
    mode TEXT NOT NULL CHECK (mode IN ('run', 'drain', 'worker')),
    request_id UUID REFERENCES community_deletion_requests(id) ON DELETE SET NULL,
    started_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    heartbeat_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    draining BOOLEAN NOT NULL DEFAULT false,
    stopped_at TIMESTAMPTZ
);

INSERT INTO _operator_global_tables (table_name, reason) VALUES
    ('community_deletion_requests', 'deployment deletion lifecycle and frozen inventory'),
    ('community_deletion_approvals', 'deployment operator destructive approvals'),
    ('community_deletion_checkpoints', 'deployment deletion executor checkpoints and failures'),
    ('community_deletion_manifest_keys', 'deployment deletion frozen destructive key chunks'),
    ('storage_taxonomy_sweeps', 'deployment object-store taxonomy sweep evidence'),
    ('community_serving_write_leases', 'deployment serving side-effect leases drained by deletion'),
    ('community_deletion_executor_heartbeats', 'deployment deletion worker liveness');

-- Shared lock key used by both the trigger and the deletion engine. Every
-- ordinary tenant mutation takes the shared xact lock before checking state;
-- the fence transition takes the exclusive xact lock, so an already-open write
-- transaction cannot commit behind the fence and no new writer can slip ahead.
-- The PARALLEL clause is omitted: CockroachDB does not implement PARALLEL
-- SAFE/UNSAFE in CREATE FUNCTION, and the annotation only affects PostgreSQL's
-- parallel-query planning for a trivial helper. IMMUTABLE STRICT is honored on
-- both engines. Valid on PostgreSQL too.
CREATE FUNCTION community_deletion_lock_key(target UUID) RETURNS BIGINT
LANGUAGE SQL IMMUTABLE STRICT AS $$
    -- Dual-compat: md5-derived bigint key. CockroachDB has no hashtextextended;
    -- md5 + bit(64) cast is deterministic and IMMUTABLE on both engines.
    SELECT ('x' || substr(md5('buzz-community-deletion:' || target::text), 1, 16))::bit(64)::bigint
$$;

-- Keep the deletion control plane writable while its target tenant is fenced.
-- This predicate is the single SQL source of truth used by attachment and live
-- catalog validation.
-- PARALLEL clause omitted for CockroachDB compatibility (see note on
-- community_deletion_lock_key above); IMMUTABLE STRICT is kept and honored on
-- both engines. Valid on PostgreSQL too.
CREATE FUNCTION community_write_fence_excluded_table(target NAME) RETURNS BOOLEAN
LANGUAGE SQL IMMUTABLE STRICT AS $$
    SELECT target::TEXT = ANY (ARRAY[
        'community_deletion_requests',
        'community_deletion_approvals',
        'community_deletion_checkpoints',
        'community_serving_write_leases',
        'community_deletion_executor_heartbeats'
    ]::TEXT[])
$$;

-- Fleet-wide writers must filter their candidate rows through this function
-- inside the mutating statement. The shared lock and lifecycle read form one
-- indivisible admission check, so a disallowed tenant is skipped before its
-- row trigger can abort healthy tenants in the same statement.
CREATE FUNCTION community_write_allowed(target UUID) RETURNS BOOLEAN
LANGUAGE plpgsql VOLATILE AS $$
DECLARE
    lifecycle TEXT;
    -- CockroachDB does not support PERFORM, so the advisory-lock call is written
    -- as SELECT ... INTO a throwaway variable. pg_advisory_xact_lock_shared
    -- returns void, so the sink is declared TEXT (void coerces cleanly to TEXT on
    -- both engines; a numeric sink errors on PostgreSQL). Valid on PostgreSQL too.
    _dummy TEXT;
BEGIN
    IF current_setting('transaction_isolation') <> 'read committed' THEN
        RAISE EXCEPTION 'community writes require READ COMMITTED isolation'
            USING ERRCODE = 'invalid_transaction_state';
    END IF;

    IF target IS NULL THEN
        RETURN true;
    END IF;

    -- Dual-compat shared lock via the keyed xact_advisory_locks table (created in
    -- migration 0023) — CockroachDB has no advisory-lock builtins. The deletion
    -- worker's exclusive fence (Rust) takes xact_lock_exclusive on the same key.
    SELECT xact_lock_shared(community_deletion_lock_key(target)) INTO _dummy;
    SELECT deletion_state
      INTO lifecycle
      FROM communities
     WHERE id = target;
    -- deletion_state is NOT NULL, so a missing community leaves lifecycle NULL;
    -- that replaces the bare FOUND flag (a column reference on CockroachDB).
    RETURN lifecycle IS NOT NULL AND lifecycle = 'active';
END
$$;

CREATE FUNCTION assert_community_write_allowed(target UUID) RETURNS VOID
LANGUAGE plpgsql AS $$
DECLARE
    lifecycle TEXT;
    generation BIGINT;
    executor_community TEXT;
    executor_generation TEXT;
    serving_community TEXT;
    serving_lease_id TEXT;
    serving_owner TEXT;
    serving_generation TEXT;
    serving_fence_generation TEXT;
    serving_lease_valid BOOLEAN := false;
    -- Throwaway sink for the advisory lock (CockroachDB has no PERFORM). See the
    -- note on community_write_allowed for why this is TEXT. Valid on PostgreSQL.
    _dummy TEXT;
BEGIN
    -- The fence proof depends on a fresh statement snapshot after the shared
    -- advisory lock is granted. Pinned RR/Serializable snapshots can retain a
    -- pre-fence lifecycle or executor generation and resurrect tenant data.
    IF current_setting('transaction_isolation') <> 'read committed' THEN
        RAISE EXCEPTION 'community writes require READ COMMITTED isolation'
            USING ERRCODE = 'invalid_transaction_state';
    END IF;

    -- Nullable operator-attribution rows without a tenant are unrelated.
    IF target IS NULL THEN
        RETURN;
    END IF;

    -- Dual-compat shared lock via the keyed xact_advisory_locks table (created in
    -- migration 0023) — CockroachDB has no advisory-lock builtins. The deletion
    -- worker's exclusive fence (Rust) takes xact_lock_exclusive on the same key.
    SELECT xact_lock_shared(community_deletion_lock_key(target)) INTO _dummy;
    SELECT deletion_state, deletion_fence_generation
      INTO lifecycle, generation
      FROM communities
     WHERE id = target;
    -- deletion_state is NOT NULL, so lifecycle IS NULL iff no row was found; this
    -- replaces the bare FOUND flag, which CockroachDB reads as a column.
    IF lifecycle IS NULL THEN
        RAISE EXCEPTION 'community write rejected: community % is missing', target
            USING ERRCODE = 'object_not_in_prerequisite_state';
    END IF;

    -- Authorization is evaluated independently for every community checked.
    executor_community := current_setting('buzz.deletion_executor_community', true);
    executor_generation := current_setting('buzz.deletion_fence_generation', true);
    IF executor_community = target::TEXT
       AND executor_generation ~ '^[0-9]+$'
       AND executor_generation::BIGINT = generation THEN
        RETURN;
    END IF;

    -- A serving mutation admitted before quiescing may finish only while its
    -- exact durable lease remains current and bound to this fence generation.
    serving_community := current_setting('buzz.serving_write_community', true);
    serving_lease_id := current_setting('buzz.serving_write_lease_id', true);
    serving_owner := current_setting('buzz.serving_write_owner', true);
    serving_generation := current_setting('buzz.serving_write_generation', true);
    serving_fence_generation := current_setting('buzz.serving_write_fence_generation', true);
    IF lifecycle IN ('active', 'quiescing')
       AND serving_community = target::TEXT
       AND serving_lease_id ~ '^[0-9a-fA-F-]{36}$'
       AND serving_generation ~ '^[0-9]+$'
       AND serving_fence_generation ~ '^[0-9]+$'
       AND serving_fence_generation::BIGINT = generation THEN
        SELECT EXISTS(
            SELECT 1 FROM community_serving_write_leases lease
             WHERE lease.id = serving_lease_id::UUID
               AND lease.community_id = target
               AND lease.owner = serving_owner
               AND lease.generation = serving_generation::BIGINT
               AND lease.fence_generation = serving_fence_generation::BIGINT
               AND lease.lease_until >= now()
        ) INTO serving_lease_valid;
        IF serving_lease_valid THEN
            RETURN;
        END IF;
    END IF;

    IF lifecycle <> 'active' THEN
        RAISE EXCEPTION 'community write fenced: community % generation %', target, generation
            USING ERRCODE = 'object_not_in_prerequisite_state';
    END IF;
END
$$;

CREATE FUNCTION enforce_community_write_fence() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
DECLARE
    -- CockroachDB does not support PERFORM, so each void assert call is written
    -- as SELECT ... INTO a throwaway TEXT sink (void coerces to TEXT on both
    -- engines). Composite OLD/NEW field access is parenthesized so it parses on
    -- CockroachDB. Both rewrites are valid on PostgreSQL too.
    _dummy TEXT;
BEGIN
    IF TG_OP = 'INSERT' THEN
        SELECT assert_community_write_allowed((NEW).community_id) INTO _dummy;
    ELSIF TG_OP = 'DELETE' THEN
        SELECT assert_community_write_allowed((OLD).community_id) INTO _dummy;
    ELSIF (OLD).community_id IS NOT DISTINCT FROM (NEW).community_id THEN
        SELECT assert_community_write_allowed((OLD).community_id) INTO _dummy;
    ELSIF (OLD).community_id IS NULL THEN
        SELECT assert_community_write_allowed((NEW).community_id) INTO _dummy;
    ELSIF (NEW).community_id IS NULL THEN
        SELECT assert_community_write_allowed((OLD).community_id) INTO _dummy;
    ELSIF (OLD).community_id < (NEW).community_id THEN
        SELECT assert_community_write_allowed((OLD).community_id) INTO _dummy;
        SELECT assert_community_write_allowed((NEW).community_id) INTO _dummy;
    ELSE
        SELECT assert_community_write_allowed((NEW).community_id) INTO _dummy;
        SELECT assert_community_write_allowed((OLD).community_id) INTO _dummy;
    END IF;

    RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
END
$$;

-- Protect the tombstone row itself. Normal updates are permitted only while the
-- row is active and do not change deletion metadata. Deletion executor updates
-- must present the exact durable generation in session-local GUCs.
CREATE FUNCTION enforce_community_tombstone() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
DECLARE
    executor_community TEXT := current_setting('buzz.deletion_executor_community', true);
    executor_generation TEXT := current_setting('buzz.deletion_fence_generation', true);
    expected_generation BIGINT;
BEGIN
    -- Composite OLD/NEW field access is parenthesized as (OLD).x / (NEW).x so it
    -- parses on CockroachDB. Valid on PostgreSQL too.
    IF TG_OP = 'DELETE' THEN
        IF (OLD).deletion_state <> 'active' OR (OLD).deleted_at IS NOT NULL THEN
            RAISE EXCEPTION 'community tombstones are permanent'
                USING ERRCODE = 'object_not_in_prerequisite_state';
        END IF;
        RETURN OLD;
    END IF;

    expected_generation := CASE
        WHEN (NEW).deletion_fence_generation > (OLD).deletion_fence_generation
            THEN (NEW).deletion_fence_generation
        ELSE (OLD).deletion_fence_generation
    END;
    IF executor_community = (OLD).id::text
       AND executor_generation ~ '^[0-9]+$'
       AND executor_generation::BIGINT = expected_generation THEN
        RETURN NEW;
    END IF;

    IF (OLD).deletion_state <> 'active'
       OR (NEW).deletion_state <> (OLD).deletion_state
       OR (NEW).deletion_fence_generation <> (OLD).deletion_fence_generation
       OR (NEW).deleted_at IS DISTINCT FROM (OLD).deleted_at THEN
        RAISE EXCEPTION 'community tombstone mutation rejected: community % generation %',
            (OLD).id, (OLD).deletion_fence_generation
            USING ERRCODE = 'object_not_in_prerequisite_state';
    END IF;
    RETURN NEW;
END
$$;

CREATE TRIGGER communities_deletion_tombstone
BEFORE UPDATE OR DELETE ON communities
FOR EACH ROW EXECUTE FUNCTION enforce_community_tombstone();

-- Attach the universal write fence to every community-scoped relation.
--
-- Original design attached the fence dynamically: a plpgsql helper
-- attach_community_write_fence(REGCLASS) scanned pg_class/pg_attribute and ran
-- EXECUTE 'CREATE TRIGGER ...' for the target, and a DO block looped over every
-- table carrying community_id (minus the control-plane sidecars) to call it.
-- CockroachDB supports neither DDL inside a routine nor dynamic plpgsql EXECUTE
-- (stmt_dyn_exec), so neither the helper nor the DO loop can exist there — the
-- CREATE FUNCTION itself is rejected before any table is fenced.
--
-- The dynamic mechanism is therefore replaced by explicit, static CREATE
-- TRIGGER statements — one per community-scoped table the loop would have
-- targeted, i.e. every table carrying community_id after migrations 0001-0028
-- EXCEPT the deletion control-plane sidecars enumerated in
-- community_write_fence_excluded_table() (which must stay writable while their
-- tenant is fenced). Semantics are preserved exactly: the same
-- enforce_community_write_fence() function, the same BEFORE INSERT OR UPDATE OR
-- DELETE / FOR EACH ROW timing, and the same trigger name
-- community_write_fence_<table> the dynamic code emitted — so later migrations
-- that reference a fence trigger by name (e.g. 0030's DROP TRIGGER for the two
-- operator-global tables) continue to match. This is valid on PostgreSQL too.
--
-- Contract for future migrations: a migration that introduces a new
-- community_id-bearing table must add an explicit CREATE TRIGGER
-- community_write_fence_<table> here-style (there is no longer a dynamic scan to
-- pick it up automatically).
CREATE TRIGGER community_write_fence_api_tokens BEFORE INSERT OR UPDATE OR DELETE ON api_tokens
FOR EACH ROW EXECUTE FUNCTION enforce_community_write_fence();
CREATE TRIGGER community_write_fence_archived_identities BEFORE INSERT OR UPDATE OR DELETE ON archived_identities
FOR EACH ROW EXECUTE FUNCTION enforce_community_write_fence();
CREATE TRIGGER community_write_fence_audit_log BEFORE INSERT OR UPDATE OR DELETE ON audit_log
FOR EACH ROW EXECUTE FUNCTION enforce_community_write_fence();
CREATE TRIGGER community_write_fence_channel_members BEFORE INSERT OR UPDATE OR DELETE ON channel_members
FOR EACH ROW EXECUTE FUNCTION enforce_community_write_fence();
CREATE TRIGGER community_write_fence_channels BEFORE INSERT OR UPDATE OR DELETE ON channels
FOR EACH ROW EXECUTE FUNCTION enforce_community_write_fence();
CREATE TRIGGER community_write_fence_community_bans BEFORE INSERT OR UPDATE OR DELETE ON community_bans
FOR EACH ROW EXECUTE FUNCTION enforce_community_write_fence();
CREATE TRIGGER community_write_fence_delivery_log BEFORE INSERT OR UPDATE OR DELETE ON delivery_log
FOR EACH ROW EXECUTE FUNCTION enforce_community_write_fence();
CREATE TRIGGER community_write_fence_event_mentions BEFORE INSERT OR UPDATE OR DELETE ON event_mentions
FOR EACH ROW EXECUTE FUNCTION enforce_community_write_fence();
CREATE TRIGGER community_write_fence_events BEFORE INSERT OR UPDATE OR DELETE ON events
FOR EACH ROW EXECUTE FUNCTION enforce_community_write_fence();
CREATE TRIGGER community_write_fence_git_repo_names BEFORE INSERT OR UPDATE OR DELETE ON git_repo_names
FOR EACH ROW EXECUTE FUNCTION enforce_community_write_fence();
CREATE TRIGGER community_write_fence_join_policy_acceptances BEFORE INSERT OR UPDATE OR DELETE ON join_policy_acceptances
FOR EACH ROW EXECUTE FUNCTION enforce_community_write_fence();
CREATE TRIGGER community_write_fence_moderation_actions BEFORE INSERT OR UPDATE OR DELETE ON moderation_actions
FOR EACH ROW EXECUTE FUNCTION enforce_community_write_fence();
CREATE TRIGGER community_write_fence_moderation_reports BEFORE INSERT OR UPDATE OR DELETE ON moderation_reports
FOR EACH ROW EXECUTE FUNCTION enforce_community_write_fence();
CREATE TRIGGER community_write_fence_parameterized_event_watermarks BEFORE INSERT OR UPDATE OR DELETE ON parameterized_event_watermarks
FOR EACH ROW EXECUTE FUNCTION enforce_community_write_fence();
CREATE TRIGGER community_write_fence_product_feedback BEFORE INSERT OR UPDATE OR DELETE ON product_feedback
FOR EACH ROW EXECUTE FUNCTION enforce_community_write_fence();
CREATE TRIGGER community_write_fence_pubkey_allowlist BEFORE INSERT OR UPDATE OR DELETE ON pubkey_allowlist
FOR EACH ROW EXECUTE FUNCTION enforce_community_write_fence();
CREATE TRIGGER community_write_fence_push_leases BEFORE INSERT OR UPDATE OR DELETE ON push_leases
FOR EACH ROW EXECUTE FUNCTION enforce_community_write_fence();
CREATE TRIGGER community_write_fence_push_match_queue BEFORE INSERT OR UPDATE OR DELETE ON push_match_queue
FOR EACH ROW EXECUTE FUNCTION enforce_community_write_fence();
CREATE TRIGGER community_write_fence_push_wake_outbox BEFORE INSERT OR UPDATE OR DELETE ON push_wake_outbox
FOR EACH ROW EXECUTE FUNCTION enforce_community_write_fence();
CREATE TRIGGER community_write_fence_rate_limit_violations BEFORE INSERT OR UPDATE OR DELETE ON rate_limit_violations
FOR EACH ROW EXECUTE FUNCTION enforce_community_write_fence();
CREATE TRIGGER community_write_fence_reactions BEFORE INSERT OR UPDATE OR DELETE ON reactions
FOR EACH ROW EXECUTE FUNCTION enforce_community_write_fence();
CREATE TRIGGER community_write_fence_relay_invites BEFORE INSERT OR UPDATE OR DELETE ON relay_invites
FOR EACH ROW EXECUTE FUNCTION enforce_community_write_fence();
CREATE TRIGGER community_write_fence_relay_members BEFORE INSERT OR UPDATE OR DELETE ON relay_members
FOR EACH ROW EXECUTE FUNCTION enforce_community_write_fence();
CREATE TRIGGER community_write_fence_scheduled_workflow_fires BEFORE INSERT OR UPDATE OR DELETE ON scheduled_workflow_fires
FOR EACH ROW EXECUTE FUNCTION enforce_community_write_fence();
CREATE TRIGGER community_write_fence_subscriptions BEFORE INSERT OR UPDATE OR DELETE ON subscriptions
FOR EACH ROW EXECUTE FUNCTION enforce_community_write_fence();
CREATE TRIGGER community_write_fence_thread_metadata BEFORE INSERT OR UPDATE OR DELETE ON thread_metadata
FOR EACH ROW EXECUTE FUNCTION enforce_community_write_fence();
CREATE TRIGGER community_write_fence_users BEFORE INSERT OR UPDATE OR DELETE ON users
FOR EACH ROW EXECUTE FUNCTION enforce_community_write_fence();
CREATE TRIGGER community_write_fence_workflow_approvals BEFORE INSERT OR UPDATE OR DELETE ON workflow_approvals
FOR EACH ROW EXECUTE FUNCTION enforce_community_write_fence();
CREATE TRIGGER community_write_fence_workflow_runs BEFORE INSERT OR UPDATE OR DELETE ON workflow_runs
FOR EACH ROW EXECUTE FUNCTION enforce_community_write_fence();
CREATE TRIGGER community_write_fence_workflows BEFORE INSERT OR UPDATE OR DELETE ON workflows
FOR EACH ROW EXECUTE FUNCTION enforce_community_write_fence();
