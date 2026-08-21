#!/usr/bin/env bash
#
# dual-db-migrate-check.sh — apply every migrations/*.sql to a fresh Postgres
# database AND a fresh CockroachDB database, reporting per-file ok/FAIL plus a
# final PASS/FAIL tally for each engine.
#
# This is the schema half of the Postgres -> CockroachDB port acceptance gate:
# repo-push-smoke.sh proves the runtime SQL round-trips; this proves the DDL in
# migrations/ applies cleanly on both engines. Run it after adding or editing a
# migration to catch CRDB-incompatible DDL before it lands.
#
# Each engine gets its own throwaway scratch database, dropped and recreated on
# every run so the check always starts from empty:
#   Postgres    -> buzz_migcheck_pg
#   CockroachDB -> buzz_migcheck_crdb
# It NEVER touches a database named 'buzz'.
#
# Usage:
#   scripts/dual-db-migrate-check.sh              # both engines, defaults below
#   PG_ONLY=1   scripts/dual-db-migrate-check.sh  # only Postgres
#   CRDB_ONLY=1 scripts/dual-db-migrate-check.sh  # only CockroachDB
#
# Env (override connection to the *server*; the scratch db name is appended):
#   PG_URL      base Postgres URL   (default: postgresql://buzz:buzz_dev@localhost:5432)
#   CRDB_URL    base CockroachDB URL(default: postgresql://root@localhost:26257?sslmode=disable)
#   PSQL        psql binary         (default: psql)
#   PG_ONLY / CRDB_ONLY  restrict to a single engine
#
set -euo pipefail

# ── Config (override via env) ───────────────────────────────────────────────
PG_URL="${PG_URL:-postgresql://buzz:buzz_dev@localhost:5432}"
CRDB_URL="${CRDB_URL:-postgresql://root@localhost:26257?sslmode=disable}"
PSQL="${PSQL:-psql}"
PG_ONLY="${PG_ONLY:-0}"
CRDB_ONLY="${CRDB_ONLY:-0}"

PG_DB="buzz_migcheck_pg"
CRDB_DB="buzz_migcheck_crdb"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MIG_DIR="${REPO_ROOT}/migrations"

# ── Pretty output ───────────────────────────────────────────────────────────
if [[ -t 1 ]]; then B=$'\033[1m'; G=$'\033[32m'; R=$'\033[31m'; Y=$'\033[33m'; N=$'\033[0m'; else B=; G=; R=; Y=; N=; fi
step() { printf '\n%s==>%s %s\n' "$B" "$N" "$*"; }
ok()   { printf '%s  ok%s %s\n' "$G" "$N" "$*"; }
warn() { printf '%s warn%s %s\n' "$Y" "$N" "$*"; }
die()  { printf '%s fail%s %s\n' "$R" "$N" "$*" >&2; exit 1; }

# ── Preflight ───────────────────────────────────────────────────────────────
command -v "$PSQL" >/dev/null 2>&1 || die "psql not found (set PSQL=/path/to/psql)"
[[ -d "$MIG_DIR" ]] || die "migrations directory not found: $MIG_DIR"

# Collect migrations in sorted order (numeric prefixes sort lexically).
MIGRATIONS=()
while IFS= read -r f; do MIGRATIONS+=("$f"); done < <(find "$MIG_DIR" -maxdepth 1 -name '*.sql' -type f | sort)
[[ ${#MIGRATIONS[@]} -gt 0 ]] || die "no *.sql files found in $MIG_DIR"
ok "found ${#MIGRATIONS[@]} migration file(s) in $MIG_DIR"

# Build a "base@dbname" connection string from a base URL, inserting the db name
# path segment before any '?query' so options like sslmode are preserved.
url_with_db() {
  local base="$1" db="$2"
  if [[ "$base" == *\?* ]]; then
    printf '%s/%s&%s' "${base%%\?*}" "$db" "${base#*\?}"
  else
    printf '%s/%s' "$base" "$db"
  fi
}

# psql against a full connection URL, quietly, failing on the first SQL error.
run_sql() {  # run_sql <conn_url> <file>
  "$PSQL" "$1" \
    --quiet --no-psqlrc \
    -v ON_ERROR_STOP=1 \
    -f "$2"
}
run_stmt() { # run_stmt <conn_url> <sql>
  "$PSQL" "$1" --quiet --no-psqlrc -v ON_ERROR_STOP=1 -c "$2"
}

# ── Per-engine driver ───────────────────────────────────────────────────────
# check_engine <label> <base_url> <scratch_db>
# Sets globals: ENGINE_PASS ENGINE_FAIL ENGINE_RESULT
check_engine() {
  local label="$1" base="$2" db="$3"
  ENGINE_PASS=0
  ENGINE_FAIL=0
  ENGINE_RESULT="FAIL"

  # Refuse to ever operate on a database literally named 'buzz'.
  if [[ "$db" == "buzz" ]]; then
    die "refusing to use scratch database named 'buzz' for $label"
  fi

  local admin_url scratch_url
  admin_url="$(url_with_db "$base" "postgres")"
  scratch_url="$(url_with_db "$base" "$db")"

  step "[$label] connecting to server and (re)creating scratch database '$db'"
  if ! run_stmt "$admin_url" "SELECT 1" >/dev/null 2>&1; then
    warn "[$label] cannot reach server at ${base} (is it running?) — skipping"
    ENGINE_RESULT="SKIP"
    return 1
  fi
  run_stmt "$admin_url" "DROP DATABASE IF EXISTS ${db}" >/dev/null \
    || die "[$label] failed to drop scratch database ${db}"
  run_stmt "$admin_url" "CREATE DATABASE ${db}" >/dev/null \
    || die "[$label] failed to create scratch database ${db}"
  ok "[$label] fresh scratch database ready: ${db}"

  step "[$label] applying ${#MIGRATIONS[@]} migration(s)"
  local f base_name
  for f in "${MIGRATIONS[@]}"; do
    base_name="$(basename "$f")"
    if run_sql "$scratch_url" "$f" >/dev/null 2>&1; then
      ok "[$label] $base_name"
      ENGINE_PASS=$((ENGINE_PASS + 1))
    else
      printf '%s FAIL%s [%s] %s\n' "$R" "$N" "$label" "$base_name" >&2
      # Re-run to surface the actual error for the log (non-fatal).
      run_sql "$scratch_url" "$f" 2>&1 | sed "s/^/    [$label] /" >&2 || true
      ENGINE_FAIL=$((ENGINE_FAIL + 1))
    fi
  done

  if [[ "$ENGINE_FAIL" -eq 0 ]]; then
    ENGINE_RESULT="PASS"
  else
    ENGINE_RESULT="FAIL"
  fi
  return 0
}

# ── Run engines ─────────────────────────────────────────────────────────────
PG_RESULT="SKIP"; PG_PASS=0; PG_FAIL=0
CRDB_RESULT="SKIP"; CRDB_PASS=0; CRDB_FAIL=0

if [[ "$CRDB_ONLY" != "1" ]]; then
  check_engine "postgres" "$PG_URL" "$PG_DB" || true
  PG_RESULT="$ENGINE_RESULT"; PG_PASS="$ENGINE_PASS"; PG_FAIL="$ENGINE_FAIL"
fi

if [[ "$PG_ONLY" != "1" ]]; then
  check_engine "cockroachdb" "$CRDB_URL" "$CRDB_DB" || true
  CRDB_RESULT="$ENGINE_RESULT"; CRDB_PASS="$ENGINE_PASS"; CRDB_FAIL="$ENGINE_FAIL"
fi

# ── Summary ─────────────────────────────────────────────────────────────────
color_result() { case "$1" in PASS) printf '%sPASS%s' "$G" "$N";; FAIL) printf '%sFAIL%s' "$R" "$N";; *) printf '%sSKIP%s' "$Y" "$N";; esac; }

step "Summary"
printf '  postgres    : %s  (%d ok / %d failed of %d)\n' "$(color_result "$PG_RESULT")"   "$PG_PASS"   "$PG_FAIL"   "${#MIGRATIONS[@]}"
printf '  cockroachdb : %s  (%d ok / %d failed of %d)\n' "$(color_result "$CRDB_RESULT")" "$CRDB_PASS" "$CRDB_FAIL" "${#MIGRATIONS[@]}"

# Exit non-zero if either engine that actually ran reported failures.
EXIT=0
[[ "$PG_RESULT"   == "FAIL" ]] && EXIT=1
[[ "$CRDB_RESULT" == "FAIL" ]] && EXIT=1
exit "$EXIT"
