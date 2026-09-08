---
name: delegate-coding
description: Delegates Coding to a Cloud setup
---

# Delegate Coding

This skills allows the user to start a remote coding agent according to the Gale ecosystem, using the API exposed by the `gale-ms-dispatcher` microservice, documented in `nicolasances/gale-ms-dispatcher`.

## When to use this skill

Whenever the user has expressed the will to delegate a coding task to a remote cloud environment.
Trigger sentences include:
- "delegate this to a coding agent"
- "delegate this to Gale coding agent"

Ambiguous sentences such as the following should NOT trigger this skill:
- "delegate this task" - could be a non-coding task
- "delegate to a remote agent" - could be any task

A trigger sentence **must include the words "coding agent"** otherwise the user could refer to other agents or workflows.

## What the remote agent needs

The `agent-coder` agent works from **a GitHub Issue**. It is not given a prompt: it is given an issue URL and a repo, and it goes and implements what the issue describes. So this skill always needs a specific issue to delegate.

## Prerequisites

Check these before dispatching, and stop with a clear message if one is missing:

- `GALE_DISPATCHER_API_ENDPOINT` environment variable is set
- The auth token is in the macOS Keychain under service `tome-ms-language-api-dev`, account `token`. Verify without printing it: `security find-generic-password -s "tome-ms-language-api-dev" -a "token" >/dev/null`. Override the service name with `GALE_DISPATCHER_TOKEN_SERVICE` if the user keeps the token elsewhere.
- `gh` is authenticated for the repo the issue lives in.

**Never print, log or echo the token**, and never pass it as a command-line argument. Only the script reads it, and it reads it straight from the Keychain.

## Workflow

### 1. Identify the issue

Resolve what the user is referring to into **one full issue URL** (`https://github.com/{owner}/{repo}/issues/{n}`).

- A URL is used as given.
- A bare number (`#42`, `issue 42`) resolves against the repo of the current working directory: `gh repo view --json nameWithOwner -q .nameWithOwner`.
- If the user just says "this issue" and the conversation has been working on one, use that one, and say which one you picked.
- If you cannot resolve exactly one issue, ask. Do not guess between candidates.

### 2. Verify the issue is available

```bash
gh issue view <issueURL> --json number,title,url,state,stateReason,assignees,labels
```

The issue is **available** when it exists and its `state` is `OPEN`.

Stop and report, rather than dispatching, when:
- the command fails — the issue does not exist, or `gh` has no access to that repo;
- the `state` is `CLOSED` — there is nothing to implement;
- the issue already has assignees, or carries a label suggesting work is under way (`in progress`, `wip`). This is not a hard block: report it and ask the user whether to dispatch anyway.

Show the user the issue number and title before dispatching, so a wrong issue is caught before an agent starts on it.

### 3. Dispatch

```bash
scripts/dispatch-coding-task.sh --issue <issueURL> [--base-branch <branch>]
```

- `--repo` is derived from the issue URL (`https://github.com/{owner}/{repo}.git`). Pass it explicitly only if the user wants the agent to work on a different repo than the one holding the issue.
- `--base-branch` is left out unless the user names a branch. The agent owns its own default (`main`); do not default it here.

The script calls `POST {GALE_DISPATCHER_API_ENDPOINT}/agents/agent-coder/tasks` with:

```json
{
  "repoURL": "https://github.com/nicolasances/agent-coder.git",
  "issueURL": "https://github.com/nicolasances/agent-coder/issues/3",
  "baseBranch": "main"
}
```

### 4. Report the result

The dispatch succeeded when the API answered **2xx** — the endpoint returns **`201`**, not `200`.

Show the user the HTTP status and **the full response payload**, which carries:

| Field | What it is |
| ----- | ---------- |
| `taskId` | The handle for this run. This is what the user needs to follow it up. |
| `agentId` | `agent-coder`. |
| `status` | `running` on a successful dispatch. |
| `taskFile` | `gs://` path of the Task File the agent was given. |

The script exits `0` on 2xx, `1` on a usage or configuration error, and `2` when the API refused the dispatch.

A successful dispatch means the agent **started**, not that the issue was implemented. Say so — the user still has to check the run's outcome.

### 5. On failure

Show the status and the response body, and read it against what the dispatcher documents:

| Code | Meaning | What to do |
| ---- | ------- | ---------- |
| `400` | The body is not a JSON object, or a required field (`repoURL`, `issueURL`) is missing or blank. The response names every missing field. | Fix the payload and retry. |
| `401` | The token is missing, expired or not accepted. | Ask the user to refresh the Keychain entry. Do not attempt to mint a token. |
| `404` | No agent registered under `agent-coder`. | Report it — this is a dispatcher-side configuration issue. |
| `500` | The Task File could not be written, or the Cloud Run Job could not be started. | The task is recorded as `failed_to_start`. Retrying is safe but mints a **new** `taskId` — the endpoint has no idempotency key, so never retry silently. Ask first. |

## Reference

- Endpoint contract: [`docs/interfaces/api-endpoints.md`](https://github.com/nicolasances/gale-ms-dispatcher/blob/main/docs/interfaces/api-endpoints.md) in `nicolasances/gale-ms-dispatcher`.
- The agent itself: `nicolasances/agent-coder`.
