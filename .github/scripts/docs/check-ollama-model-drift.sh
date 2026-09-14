#!/usr/bin/env bash
#
# check-ollama-model-drift.sh
#
# Guards against the docs drifting out of sync with the Ollama model name that
# is the source of truth in the rossoctl/examples repo.
#
# Checks the model table in docs/get-started/configure-a-model.md, whose
# `ollama`-preset row names the model verbatim (e.g. "The default in the
# `ollama` preset"). The source of truth is the weather demo's `.env.ollama`
# in rossoctl/examples — the sole agent that publishes one. If the examples
# repo repins its model and the docs page is not updated, this fails.
#
# The doc must contain the model as a substring (grep -F). The page is a menu
# of tested models, so the guarded value can move rows without breaking the
# check, as long as the current `.env.ollama` model still appears somewhere on
# the page.
#
# Exit codes: 0 = in sync, 1 = drift detected, 2 = could not fetch source.

set -euo pipefail

# doc_path <TAB> raw_env_url
CHECKS=(
  "docs/get-started/configure-a-model.md	https://raw.githubusercontent.com/rossoctl/examples/refs/heads/main/a2a/weather_service/.env.ollama"
)

fetch_with_retry() {
  # $1 = url. Retries to absorb transient network flake.
  local url="$1" attempt
  for attempt in 1 2 3; do
    if curl -fsSL --max-time 20 "$url"; then
      return 0
    fi
    echo "  fetch attempt ${attempt} failed for ${url}" >&2
    sleep $((attempt * 2))
  done
  return 1
}

status=0
for entry in "${CHECKS[@]}"; do
  doc="${entry%%$'\t'*}"
  url="${entry##*$'\t'}"

  echo "Checking ${doc} against ${url}"

  if [[ ! -f "${doc}" ]]; then
    echo "::error file=${doc}::doc not found" >&2
    status=1
    continue
  fi

  env_contents="$(fetch_with_retry "${url}")" || {
    echo "::error::could not fetch ${url} after retries (network flake?)" >&2
    status=2
    continue
  }

  # Extract LLM_MODEL=... (tolerate optional quotes/whitespace).
  model="$(printf '%s\n' "${env_contents}" \
    | grep -iE '^[[:space:]]*LLM_MODEL[[:space:]]*=' \
    | head -1 \
    | sed -E 's/^[^=]*=[[:space:]]*//; s/^["'\'']//; s/["'\'']$//; s/[[:space:]]*$//')"

  if [[ -z "${model}" ]]; then
    echo "::error::no LLM_MODEL found in ${url}" >&2
    status=2
    continue
  fi

  if grep -qF -- "${model}" "${doc}"; then
    echo "  OK: '${model}' present in ${doc}"
  else
    echo "::error file=${doc}::model '${model}' from ${url} not found in ${doc} (docs drifted?)" >&2
    status=1
  fi
done

if [[ "${status}" -eq 0 ]]; then
  echo "All Ollama model references are in sync."
fi
exit "${status}"
