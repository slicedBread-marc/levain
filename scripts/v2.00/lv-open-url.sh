#!/usr/bin/env bash
# lv-open-url.sh [--as <account>] [--fresh] [--dry-run] <url>
#
# Opens a URL for the human in their browser, so an attended /lv-accept hands
# over a window instead of a link to copy. With --as, the window is already
# signed in as that account: the human is told which account a criterion needs
# and never has to pick it out of a list.
#
#   lv-open-url.sh http://localhost:8091/learners/new
#   lv-open-url.sh --as parent@example.test http://localhost:8091/household
#
# Sign-in comes from `test_signin_url` in levain.yml: a URL template that signs
# an account in with one GET. `{account}` is replaced by the account and
# `{return}` by the target URL, both URL-encoded. A template with `{return}`
# is opened alone; one without it is opened first, and the target a moment
# later (LV_OPEN_DELAY seconds, default 2) once its cookie has landed. e.g.
#
#   test_signin_url: "http://localhost:8084/dev/login?fixture={account}"
#
# No template: the target opens and the script says which account to choose.
#
# Each account gets its own browser profile under
# $TMPDIR/lv-browser/<project_slug>/<account>, so switching accounts between
# criteria needs no sign-out, and cookies from other local apps (localhost
# cookies ignore the port) cannot cause redirect loops. --fresh empties that
# profile first: use it on the first open of an account in a session, because
# a profile signed in against a database that has since been reset loops too.
#
# The browser is `test_browser` in levain.yml (default "Google Chrome"). On a
# machine without it, or without macOS `open`, the URL goes to the default
# browser with no profile, or is just printed.
#
# Never opens anything under LV_UNATTENDED=1: there is nobody to look at it.
#
# Prints OPENED=<url> for each URL opened and SIGN_IN_AS=<account> with --as.
# Exit 0 when opened (or skipped unattended), 2 on usage.

set -euo pipefail

# shellcheck source=lv-orch-lib.sh
source "$(dirname "$0")/lv-orch-lib.sh"

account=""
fresh=false
dry=false
url=""

while [ $# -gt 0 ]; do
  case "$1" in
    --as) [ $# -ge 2 ] || { echo "--as needs an account" >&2; exit 2; }; account="$2"; shift 2 ;;
    --fresh) fresh=true; shift ;;
    --dry-run) dry=true; shift ;;
    -*) echo "Unknown option: $1" >&2; exit 2 ;;
    *) [ -z "$url" ] || { echo "One URL only" >&2; exit 2; }; url="$1"; shift ;;
  esac
done

[ -n "$url" ] || { echo "Usage: $0 [--as <account>] [--fresh] [--dry-run] <url>" >&2; exit 2; }

if [ "${LV_UNATTENDED:-}" = "1" ]; then
  echo "lv-open-url: unattended — not opening $url" >&2
  exit 0
fi

urlencode() {
  local s="$1" out="" c i
  for (( i = 0; i < ${#s}; i++ )); do
    c="${s:i:1}"
    case "$c" in
      [a-zA-Z0-9.~_-]) out+="$c" ;;
      *) out+=$(printf '%%%02X' "'$c") ;;
    esac
  done
  printf '%s' "$out"
}

browser=$(wf_cfg test_browser "Google Chrome")
template=$(wf_cfg test_signin_url "")
slug=$(wf_cfg project_slug "$(basename "$(git rev-parse --show-toplevel 2>/dev/null || pwd)")")

signin=""
if [ -n "$account" ] && [ -n "$template" ]; then
  signin="${template//\{account\}/$(urlencode "$account")}"
  if [[ "$template" == *"{return}"* ]]; then
    signin="${signin//\{return\}/$(urlencode "$url")}"
  fi
fi

profile_key="${account:-guest}"
profile_key="${profile_key//[^a-zA-Z0-9.@_-]/_}"
profile="${TMPDIR:-/tmp}"
profile="${profile%/}/lv-browser/$slug/$profile_key"

run() {
  if $dry; then printf 'RUN:'; printf ' %q' "$@"; printf '\n'; else "$@"; fi
}

launch() {
  local target="$1"
  if command -v open >/dev/null 2>&1 && { $dry || open -Ra "$browser" >/dev/null 2>&1; }; then
    run open -na "$browser" --args --user-data-dir="$profile" \
      --no-first-run --no-default-browser-check "$target"
  elif command -v open >/dev/null 2>&1; then
    run open "$target"
  elif command -v xdg-open >/dev/null 2>&1; then
    run xdg-open "$target" >/dev/null 2>&1
  else
    echo "lv-open-url: no way to open a browser here — open it yourself: $target" >&2
    return 0
  fi
  echo "OPENED=$target"
}

if $fresh; then
  run rm -rf "$profile"
fi
$dry || mkdir -p "$profile"

[ -n "$account" ] && echo "SIGN_IN_AS=$account"

if [ -n "$signin" ]; then
  launch "$signin"
  if [[ "$template" != *"{return}"* ]]; then
    $dry || sleep "${LV_OPEN_DELAY:-2}"
    launch "$url"
  fi
else
  launch "$url"
  if [ -n "$account" ]; then
    echo "lv-open-url: no test_signin_url in levain.yml — sign in as $account when asked" >&2
  fi
fi
