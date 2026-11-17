#!/usr/bin/env bash
set -euo pipefail
# Policy on pull requests always comes from the event's immutable base SHA.
source_dir="${1:-.}"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
event="${GITHUB_EVENT_NAME:-local}"
if [[ "$event" == pull_request ]]; then
  policy_ref="${SECRET_SCAN_BASE_SHA:-}"
  [[ "$policy_ref" =~ ^[0-9a-f]{40}$ ]] || exit 2
else
  policy_ref=HEAD
fi
git -C "$source_dir" cat-file -e "$policy_ref^{commit}"
git_dir="$(git -C "$source_dir" rev-parse --absolute-git-dir)"
printf '[extend]\nuseDefault = true\n' > "$tmp/config.toml"
: > "$tmp/.gitleaksignore"
if git -C "$source_dir" cat-file -e "$policy_ref:.gitleaks.toml" 2>/dev/null; then
  git -C "$source_dir" show "$policy_ref:.gitleaks.toml" > "$tmp/config.toml"
fi
if git -C "$source_dir" cat-file -e "$policy_ref:.gitleaksignore" 2>/dev/null; then
  git -C "$source_dir" show "$policy_ref:.gitleaksignore" > "$tmp/.gitleaksignore"
fi
# Local, read-only mirror verification; never available in Actions or PR mode.
if [[ -n "${SECRET_SCAN_LOCAL_POLICY_DIR:-}" ]]; then
  [[ "$event" == local && "${GITHUB_ACTIONS:-false}" != true ]] || exit 2
  [[ "$(git -C "$source_dir" rev-parse --is-bare-repository)" == true ]] || exit 2
  cp "$SECRET_SCAN_LOCAL_POLICY_DIR/config.toml" "$tmp/config.toml"
  cp "$SECRET_SCAN_LOCAL_POLICY_DIR/.gitleaksignore" "$tmp/.gitleaksignore"
fi
set +e
# Scan the Git directory: gitleaks otherwise additionally loads the untrusted
# worktree .gitleaksignore even when an explicit ignore path is supplied.
gitleaks git "$git_dir" --log-opts=--all --redact=100 --ignore-gitleaks-allow \
  --config "$tmp/config.toml" --gitleaks-ignore-path "$tmp/.gitleaksignore" \
  --no-banner --log-level error > /dev/null 2>&1
status=$?
set -e
if [[ $status -eq 0 ]]; then
  printf 'VERIFIED secret scan completed without findings\n'
else
  printf 'FAILED secret scan (exit %s)\n' "$status" >&2
fi
exit "$status"
