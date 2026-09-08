#!/usr/bin/env bash
#
# Dispatches a coding task to the Gale `agent-coder` remote agent.
#
# Calls POST {GALE_DISPATCHER_API_ENDPOINT}/agents/agent-coder/tasks on the
# gale-ms-dispatcher API (nicolasances/gale-ms-dispatcher) and prints the HTTP
# status together with the response payload.
#
# Usage:
#   dispatch-coding-task.sh --issue <issueURL> [--repo <repoURL>] [--base-branch <branch>]
#
#   --issue         Full GitHub issue URL, e.g. https://github.com/nicolasances/agent-coder/issues/3
#   --repo          Clone URL of the repo. Defaults to the issue's repo, with `.git` appended.
#   --base-branch   Branch the agent branches off. Omitted by default: the agent owns its own default.
#
# Environment:
#   GALE_DISPATCHER_API_ENDPOINT   Required. Base URL of the dispatcher, including its `/dispatcher` base path.
#   GALE_DISPATCHER_TOKEN_SERVICE  Optional. macOS Keychain service holding the auth token.
#                                  Defaults to `tome-ms-language-api-dev`, account `token`.
#
# Exit codes: 0 = dispatched (2xx), 1 = usage or configuration error, 2 = the API refused the dispatch.

set -euo pipefail

KEYCHAIN_SERVICE="${GALE_DISPATCHER_TOKEN_SERVICE:-tome-ms-language-api-dev}"
KEYCHAIN_ACCOUNT="token"

ISSUE_URL=""
REPO_URL=""
BASE_BRANCH=""

die() { echo "Error: $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --issue)       ISSUE_URL="${2:-}"; shift 2 ;;
        --repo)        REPO_URL="${2:-}"; shift 2 ;;
        --base-branch) BASE_BRANCH="${2:-}"; shift 2 ;;
        -h|--help)     awk 'NR>1 && /^#/ { sub(/^# ?/, ""); print; next } NR>1 { exit }' "$0"; exit 0 ;;
        *)             die "Unknown argument: $1" ;;
    esac
done

# --- Validate inputs -----------------------------------------------------------------------------

[[ -n "$ISSUE_URL" ]] || die "--issue is required (full GitHub issue URL)"

if [[ ! "$ISSUE_URL" =~ ^https://github\.com/([^/]+)/([^/]+)/issues/[0-9]+$ ]]; then
    die "--issue must be a full GitHub issue URL, e.g. https://github.com/owner/repo/issues/3 (got: $ISSUE_URL)"
fi

# The repo URL is derived from the issue URL unless given, so the two can never point at different repos by accident.
if [[ -z "$REPO_URL" ]]; then
    REPO_URL="https://github.com/${BASH_REMATCH[1]}/${BASH_REMATCH[2]}.git"
fi

[[ -n "${GALE_DISPATCHER_API_ENDPOINT:-}" ]] || die "GALE_DISPATCHER_API_ENDPOINT is not set"

# --- Read the auth token ------------------------------------------------------------------------

TOKEN="$(security find-generic-password -s "$KEYCHAIN_SERVICE" -a "$KEYCHAIN_ACCOUNT" -w 2>/dev/null)" || \
    die "No token in the macOS Keychain under service '$KEYCHAIN_SERVICE', account '$KEYCHAIN_ACCOUNT'. Register it with: security add-generic-password -s \"$KEYCHAIN_SERVICE\" -a \"$KEYCHAIN_ACCOUNT\" -w \"<TOKEN>\""

[[ -n "$TOKEN" ]] || die "The Keychain entry '$KEYCHAIN_SERVICE' holds an empty token"

# --- Build the request --------------------------------------------------------------------------

URL="${GALE_DISPATCHER_API_ENDPOINT%/}/agents/agent-coder/tasks"

if [[ -n "$BASE_BRANCH" ]]; then
    BODY="$(jq -nc --arg repo "$REPO_URL" --arg issue "$ISSUE_URL" --arg branch "$BASE_BRANCH" \
        '{repoURL: $repo, issueURL: $issue, baseBranch: $branch}')"
else
    BODY="$(jq -nc --arg repo "$REPO_URL" --arg issue "$ISSUE_URL" \
        '{repoURL: $repo, issueURL: $issue}')"
fi

echo "Dispatching to agent-coder"
echo "  endpoint:    POST $URL"
echo "  payload:     $BODY"
echo

# --- Dispatch -----------------------------------------------------------------------------------

RESPONSE_BODY="$(mktemp)"
trap 'rm -f "$RESPONSE_BODY"' EXIT

# The Authorization header is passed through a curl config file on stdin rather than on the command
# line, so the token never shows up in the process list.
HTTP_CODE="$(printf 'header = "Authorization: Bearer %s"\n' "$TOKEN" | curl -sS -K - \
    -X POST "$URL" \
    -H "Content-Type: application/json" \
    -d "$BODY" \
    -o "$RESPONSE_BODY" \
    -w '%{http_code}')" || die "The request to the dispatcher failed (curl exit $?)"

echo "HTTP $HTTP_CODE"
echo "Response:"
jq . "$RESPONSE_BODY" 2>/dev/null || cat "$RESPONSE_BODY"
echo

if [[ "$HTTP_CODE" =~ ^2[0-9][0-9]$ ]]; then
    echo "Task dispatched."
    exit 0
fi

echo "Dispatch failed: the dispatcher answered HTTP $HTTP_CODE." >&2
exit 2
