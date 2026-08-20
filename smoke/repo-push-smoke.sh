#!/usr/bin/env bash
#
# repo-push-smoke.sh — end-to-end "add a repository" smoke test for a local Buzz relay.
#
# Exercises the full repo path against whatever database the relay is backed by:
#   1. create a channel            (kind:40000  -> buzz-db write)
#   2. announce a repo bound to it (kind:30617  -> buzz-db write, buzz-channel ACL tag)
#   3. git push a real commit      (git-receive-pack -> pack objects in S3/MinIO)
#   4. verify: query the announcement back, then clone it into a temp dir
#
# This is our reusable acceptance gate for the CockroachDB migration: run it against
# the Postgres relay to capture the baseline, then re-run it against a CRDB-backed
# relay and diff the outcome. Everything it touches (channels, repos, git ACL,
# event store) rides on buzz-db, so a green run means the SQL layer round-trips.
#
# Usage:
#   smoke/repo-push-smoke.sh                # uses defaults below
#   REPO_ID=my-test smoke/repo-push-smoke.sh
#   KEEP=1 smoke/repo-push-smoke.sh         # keep scratch dirs for inspection
#
set -euo pipefail

# ── Config (override via env) ───────────────────────────────────────────────
RELAY_HTTP="${RELAY_HTTP:-http://localhost:3000}"          # buzz-cli + git transport
KEYS_FILE="${KEYS_FILE:-/tmp/buzz-owner-keys.txt}"         # produced when the stack was brought up
REPO_ID="${REPO_ID:-smoke-repo-$(date +%s)}"              # d-tag; [a-zA-Z0-9._-]{1,64}
CHANNEL_NAME="${CHANNEL_NAME:-smoke-repos}"
KEEP="${KEEP:-0}"                                          # 1 = don't delete scratch dirs

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ── Pretty output ───────────────────────────────────────────────────────────
if [[ -t 1 ]]; then B=$'\033[1m'; G=$'\033[32m'; R=$'\033[31m'; Y=$'\033[33m'; N=$'\033[0m'; else B=; G=; R=; Y=; N=; fi
step() { printf '\n%s==>%s %s\n' "$B" "$N" "$*"; }
ok()   { printf '%s  ok%s %s\n' "$G" "$N" "$*"; }
die()  { printf '%s fail%s %s\n' "$R" "$N" "$*" >&2; exit 1; }

# ── Locate / build the two binaries we need ─────────────────────────────────
# buzz              = the buzz-cli binary (JSON-in/JSON-out relay client)
# git-credential-nostr = NIP-98 credential helper git shells out to for auth
find_bin() {
  local name="$1"
  if [[ -x "$REPO_ROOT/target/debug/$name" ]]; then echo "$REPO_ROOT/target/debug/$name"; return; fi
  if command -v "$name" >/dev/null 2>&1; then command -v "$name"; return; fi
  echo ""
}
BUZZ_BIN="$(find_bin buzz)"
GCN_BIN="$(find_bin git-credential-nostr)"
if [[ -z "$BUZZ_BIN" || -z "$GCN_BIN" ]]; then
  step "Building buzz-cli + git-credential-nostr (missing binaries)"
  ( cd "$REPO_ROOT" && cargo build -p buzz-cli -p git-credential-nostr )
  BUZZ_BIN="$(find_bin buzz)"
  GCN_BIN="$(find_bin git-credential-nostr)"
fi
[[ -x "$BUZZ_BIN" ]] || die "buzz binary not found (looked in target/debug and PATH)"
[[ -x "$GCN_BIN" ]] || die "git-credential-nostr not found (looked in target/debug and PATH)"
ok "buzz               = $BUZZ_BIN"
ok "git-credential-nostr = $GCN_BIN"

# ── Load identity ───────────────────────────────────────────────────────────
[[ -f "$KEYS_FILE" ]] || die "keys file $KEYS_FILE not found (set KEYS_FILE=...)"
OWNER_PRIV="$(awk '/owner priv/{print $3}' "$KEYS_FILE")"
OWNER_PUB="$(awk '/owner pub/{print $3}'  "$KEYS_FILE")"
[[ ${#OWNER_PRIV} -eq 64 ]] || die "owner private key in $KEYS_FILE is not 64 hex chars"
[[ ${#OWNER_PUB}  -eq 64 ]] || die "owner pubkey in $KEYS_FILE is not 64 hex chars"
ok "identity           = ${OWNER_PUB:0:16}… (relay owner)"

export BUZZ_RELAY_URL="$RELAY_HTTP"
export BUZZ_PRIVATE_KEY="$OWNER_PRIV"
export NOSTR_PRIVATE_KEY="$OWNER_PRIV"   # git-credential-nostr reads this

# jq helper — buzz-cli create commands print one JSON object
jq_field() { jq -er "$1" 2>/dev/null; }

# ── Scratch dirs ────────────────────────────────────────────────────────────
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/buzz-smoke-work.XXXXXX")"
CLONE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/buzz-smoke-clone.XXXXXX")"
cleanup() { [[ "$KEEP" == "1" ]] && { echo; echo "scratch kept: $WORK_DIR  $CLONE_DIR"; return; }; rm -rf "$WORK_DIR" "$CLONE_DIR"; }
trap cleanup EXIT

# ── 1. Create a channel ─────────────────────────────────────────────────────
step "Creating channel '$CHANNEL_NAME'"
CH_JSON="$("$BUZZ_BIN" channels create --name "$CHANNEL_NAME" --type stream --visibility open --description 'smoke-test repo channel')"
echo "$CH_JSON"
[[ "$(echo "$CH_JSON" | jq_field '.accepted')" == "true" ]] || die "channel create not accepted"
CHANNEL_ID="$(echo "$CH_JSON" | jq_field '.channel_id')"
[[ -n "$CHANNEL_ID" ]] || die "no channel_id in response"
ok "channel_id         = $CHANNEL_ID"

# ── 2. Announce the repo, bound to the channel (the buzz-channel tag = git ACL) ──
step "Announcing repo '$REPO_ID' bound to channel"
REPO_JSON="$("$BUZZ_BIN" repos create --id "$REPO_ID" --name "$REPO_ID" --description 'smoke test' --channel "$CHANNEL_ID")"
echo "$REPO_JSON"
[[ "$(echo "$REPO_JSON" | jq_field '.accepted')" == "true" ]] || die "repo announcement not accepted"
ok "repo announced     = $REPO_ID"

# ── 3. Build a real git repo and push it ────────────────────────────────────
step "Creating local commit in $WORK_DIR"
(
  cd "$WORK_DIR"
  git init -q -b main
  git config user.email smoke@buzz.local
  git config user.name  "Buzz Smoke"
  printf '# %s\n\nPushed by repo-push-smoke.sh at %s\n' "$REPO_ID" "$(date -u +%FT%TZ)" > README.md
  git add README.md
  git commit -q -m "smoke: initial commit"
)
ok "commit             = $(cd "$WORK_DIR" && git rev-parse --short HEAD)"

GIT_URL="$RELAY_HTTP/git/$OWNER_PUB/$REPO_ID.git"
step "Pushing to $GIT_URL"
git -C "$WORK_DIR" \
    -c credential.helper="$GCN_BIN" \
    -c credential.useHttpPath=true \
    push "$GIT_URL" main
ok "pushed main"

# ── 4. Verify: announcement queryable + clone round-trips ───────────────────
step "Verifying announcement is queryable"
GET_JSON="$("$BUZZ_BIN" repos get --id "$REPO_ID" --owner "$OWNER_PUB")"
echo "$GET_JSON" | jq -e --arg id "$REPO_ID" '.. | objects | select(.tags?) | .tags[] | select(.[0]=="d" and .[1]==$id)' >/dev/null \
  || die "repo announcement not found in relay query"
ok "announcement present"

step "Verifying clone round-trips from object storage"
git -c credential.helper="$GCN_BIN" -c credential.useHttpPath=true \
    clone -q "$GIT_URL" "$CLONE_DIR/repo"
[[ -f "$CLONE_DIR/repo/README.md" ]] || die "cloned repo missing README.md"
CLONED_HEAD="$(cd "$CLONE_DIR/repo" && git rev-parse HEAD)"
PUSHED_HEAD="$(cd "$WORK_DIR" && git rev-parse HEAD)"
[[ "$CLONED_HEAD" == "$PUSHED_HEAD" ]] || die "clone HEAD $CLONED_HEAD != pushed HEAD $PUSHED_HEAD"
ok "clone HEAD matches pushed HEAD ($CLONED_HEAD)"

printf '\n%s==> SMOKE PASSED%s  repo=%s channel=%s\n' "$G" "$N" "$REPO_ID" "$CHANNEL_ID"
printf '   web client: %s (community should now list this repo)\n' "http://localhost:5173"
