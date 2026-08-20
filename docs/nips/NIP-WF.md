# NIP-WF: Owner-Managed Workflow State

`draft` `optional`

## Abstract

This document defines how a human manages a workflow created by their verified NIP-OA agent without impersonating the agent or transferring execution authority.

## Event kinds

| Kind | Author | Purpose |
|---|---|---|
| `30620` | Workflow owner | Initial workflow definition and legacy same-author updates |
| `46021` | Managing actor | Append-only workflow update request |
| `30623` | Relay | Parameterized-replaceable current workflow state |
| `46020` | Managing actor | Manual trigger request |
| `5` | Managing actor | NIP-09 deletion request targeting the owner's `30620` coordinate |

## Update request

A kind `46021` event contains the proposed YAML and exactly one of each required tag:

```json
{
  "kind": 46021,
  "content": "<workflow YAML>",
  "tags": [
    ["a", "30620:<workflow-owner-pubkey>:<workflow-uuid>"],
    ["h", "<channel-uuid>"],
    ["expected-revision", "<accepted-request-event-id>"]
  ]
}
```

The event signer is the managing actor. The relay permits the request when the actor is either the stored workflow owner or the human owner of that agent according to the community-scoped, cryptographically verified NIP-OA mapping. Channel access checks still apply.

The relay evaluates elevated workflow actions and executes future runs using the unchanged stored workflow owner.

## Current state

After accepting a create, update, or deletion request, the relay publishes kind `30623` under its own key with `d` equal to the workflow UUID:

```json
{
  "kind": 30623,
  "content": "<current workflow YAML>",
  "tags": [
    ["d", "<workflow-uuid>"],
    ["h", "<channel-uuid>"],
    ["owner", "<workflow-owner-pubkey>"],
    ["actor", "<accepted-request-author>"],
    ["e", "<accepted-request-id>", "", "request"],
    ["status", "active"]
  ]
}
```

Only the configured relay identity is authoritative for kind `30623`. Clients must not infer workflow ownership from the state event's relay pubkey; they use the `owner` tag.

A deleted state has empty content and `status=deleted`. Clients prefer valid relay-signed `30623` state over legacy `30620` definitions and hide deleted state.

## Concurrency and compatibility

The relay compares `expected-revision` with the workflow's current accepted request event id in one transaction. The state event's `e` tag exposes that same request id. A stale request is rejected without changing the workflow or publishing state.

Relays continue accepting kind `30620` creation events and same-author legacy updates. New clients query both kinds and fall back to `30620` only when no valid `30623` state exists. NIP-OA never authorizes re-signing as the agent.
