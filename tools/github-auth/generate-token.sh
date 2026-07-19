#!/usr/bin/env bash
set -euo pipefail

CACHE_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/melodic/github-app-token.json"
QUIET=false

usage() {
  cat <<'EOF'
Usage: generate-token.sh [OPTIONS]

Generate a GitHub App installation token for melodic-ai[bot].

Options:
  --check    Validate prerequisites without generating a token
  --quiet    Suppress non-error output on stderr
  --help     Show this help message

Environment variables (required):
  MELODIC_APP_ID              GitHub App ID
  MELODIC_INSTALLATION_ID     GitHub App installation ID

One of (required):
  MELODIC_PRIVATE_KEY_PATH    Path to PEM private key file
  MELODIC_PRIVATE_KEY_BASE64  Base64-encoded PEM private key (cloud routines)

Output:
  Token printed to stdout. Progress/diagnostics on stderr.
  Exit 0 on success, 1 on failure.
EOF
}

log() {
  if [[ "$QUIET" != true ]]; then
    echo "$@" >&2
  fi
}

err() {
  echo "ERROR: $*" >&2
}

b64url() {
  openssl base64 -A | tr '+/' '-_' | tr -d '='
}

resolve_pem() {
  if [[ -n "${MELODIC_PRIVATE_KEY_PATH:-}" ]]; then
    if [[ ! -f "$MELODIC_PRIVATE_KEY_PATH" ]]; then
      err "PEM file not found: $MELODIC_PRIVATE_KEY_PATH"
      return 1
    fi
    echo "$MELODIC_PRIVATE_KEY_PATH"
  elif [[ -n "${MELODIC_PRIVATE_KEY_BASE64:-}" ]]; then
    local tmpfile
    tmpfile=$(mktemp)
    echo "$MELODIC_PRIVATE_KEY_BASE64" | base64 -d >"$tmpfile"
    echo "$tmpfile"
  else
    err "Neither MELODIC_PRIVATE_KEY_PATH nor MELODIC_PRIVATE_KEY_BASE64 is set"
    return 1
  fi
}

check_prerequisites() {
  local missing=()

  for cmd in openssl curl jq; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      missing+=("$cmd")
    fi
  done

  if [[ ${#missing[@]} -gt 0 ]]; then
    err "Missing required commands: ${missing[*]}"
    return 1
  fi

  if [[ -z "${MELODIC_APP_ID:-}" ]]; then
    err "MELODIC_APP_ID is not set"
    return 1
  fi

  if [[ -z "${MELODIC_INSTALLATION_ID:-}" ]]; then
    err "MELODIC_INSTALLATION_ID is not set"
    return 1
  fi

  local pem_path
  if ! pem_path=$(resolve_pem); then
    return 1
  fi

  if ! openssl rsa -in "$pem_path" -check -noout >/dev/null 2>&1; then
    [[ -z "${MELODIC_PRIVATE_KEY_PATH:-}" ]] && rm -f "$pem_path"
    err "PEM file is not a valid RSA private key"
    return 1
  fi
  [[ -z "${MELODIC_PRIVATE_KEY_PATH:-}" ]] && rm -f "$pem_path"

  log "All prerequisites OK (app_id=$MELODIC_APP_ID, installation_id=$MELODIC_INSTALLATION_ID)"
  return 0
}

try_cached_token() {
  if [[ ! -f "$CACHE_FILE" ]]; then
    return 1
  fi

  local expires_epoch token
  expires_epoch=$(jq -r '.expires_at_epoch // 0' "$CACHE_FILE" 2>/dev/null) || return 1
  token=$(jq -r '.token // empty' "$CACHE_FILE" 2>/dev/null) || return 1

  if [[ -z "$token" ]]; then
    return 1
  fi

  local now
  now=$(date +%s | tr -d '\r')
  local margin=300

  if [[ "$now" -lt $((expires_epoch - margin)) ]]; then
    log "Using cached token (expires in $(((expires_epoch - now) / 60))m)"
    echo "$token"
    return 0
  fi

  log "Cached token expires within 5 minutes, re-minting"
  return 1
}

generate_jwt() {
  local pem_path="$1"
  local now
  now=$(date +%s | tr -d '\r')
  local iat=$((now - 60))
  local exp=$((now + 600))

  local header='{"alg":"RS256","typ":"JWT"}'
  local payload
  payload=$(printf '{"iss":"%s","iat":%d,"exp":%d}' "$MELODIC_APP_ID" "$iat" "$exp")

  local header_b64 payload_b64 signature
  header_b64=$(printf '%s' "$header" | b64url)
  payload_b64=$(printf '%s' "$payload" | b64url)

  signature=$(printf '%s.%s' "$header_b64" "$payload_b64" \
    | openssl dgst -sha256 -sign "$pem_path" -binary \
    | b64url)

  printf '%s.%s.%s' "$header_b64" "$payload_b64" "$signature"
}

exchange_jwt_for_token() {
  local jwt="$1"
  local url="https://api.github.com/app/installations/${MELODIC_INSTALLATION_ID}/access_tokens"

  local response http_code body
  response=$(curl -s -w '\n%{http_code}' \
    -X POST \
    -H "Authorization: Bearer $jwt" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "$url")

  http_code=$(echo "$response" | tail -1 | tr -d '\r')
  body=$(echo "$response" | sed '$d')

  if [[ "$http_code" != "201" ]]; then
    local msg
    msg=$(echo "$body" | jq -r '.message // "unknown error"' 2>/dev/null || echo "unknown error")
    err "Token exchange failed (HTTP $http_code): $msg"
    return 1
  fi

  echo "$body"
}

cache_token() {
  local body="$1"
  local token expires_at expires_epoch

  token=$(echo "$body" | jq -r '.token' | tr -d '\r')
  expires_at=$(echo "$body" | jq -r '.expires_at' | tr -d '\r')

  # Parse ISO8601 to epoch — GNU date handles this
  expires_epoch=$(date -d "$expires_at" +%s 2>/dev/null | tr -d '\r') || expires_epoch=0

  local cache_json
  cache_json=$(jq -n \
    --arg t "$token" \
    --arg ea "$expires_at" \
    --argjson eae "$expires_epoch" \
    '{token: $t, expires_at: $ea, expires_at_epoch: $eae}')

  local cache_dir
  cache_dir=$(dirname "$CACHE_FILE")
  mkdir -p "$cache_dir"

  local old_umask
  old_umask=$(umask)
  umask 077
  local tmpfile
  tmpfile=$(mktemp "${CACHE_FILE}.XXXXXX")
  printf '%s\n' "$cache_json" >"$tmpfile"
  mv "$tmpfile" "$CACHE_FILE"
  umask "$old_umask"

  log "Token cached (expires $expires_at)"
  echo "$token"
}

main() {
  local check_only=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --check)
        check_only=true
        shift
        ;;
      --quiet)
        QUIET=true
        shift
        ;;
      --help)
        usage
        exit 0
        ;;
      *)
        err "Unknown option: $1"
        usage >&2
        exit 1
        ;;
    esac
  done

  if [[ "$check_only" == true ]]; then
    check_prerequisites
    exit $?
  fi

  if ! check_prerequisites; then
    exit 1
  fi

  if try_cached_token; then
    return 0
  fi

  local pem_path
  pem_path=$(resolve_pem)
  if [[ -z "${MELODIC_PRIVATE_KEY_PATH:-}" && -f "$pem_path" ]]; then
    # shellcheck disable=SC2064
    trap "rm -f '$pem_path'" EXIT
  fi

  log "Generating JWT..."
  local jwt
  jwt=$(generate_jwt "$pem_path")

  log "Exchanging JWT for installation token..."
  local response_body
  response_body=$(exchange_jwt_for_token "$jwt")

  cache_token "$response_body"
}

main "$@"
