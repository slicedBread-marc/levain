#!/usr/bin/env bash
# lv-lane.sh — the express lane: small, safe work that runs with no human gate.
#
#   lv-lane.sh declare  <BUG|BRF|PLN-NNN> [--trust] [--by <who>] [--no-commit]
#   lv-lane.sh declare  <BUG|BRF|PLN-NNN> --clear [--no-commit]
#   lv-lane.sh precheck <BUG|BRF-NNN>                     warn only, exit 0
#   lv-lane.sh check    <PLN-NNN> [--accept-warnings [--by <who>]] [--no-commit]
#   lv-lane.sh status   <PLN-NNN>                         eval contract, writes nothing
#   lv-lane.sh answer   <PLN-NNN> spec-approval|manual-test [--no-commit]
#   lv-lane.sh push-covered [--spend] [--quiet]
#   lv-lane.sh deferred-covered [--quiet] -- <git log revision args...>
#   lv-lane.sh budget                                     the limits, for /lv-spec
#
# WHAT IT IS
#
# Every gate in the harness is configured project-wide: specApproval.mode and
# gateTags, manualTestGate, orchestrator.autonomy. There was no way to say, for
# ONE piece of work, "this is trivial, run it to production unattended". A small
# family-app bug stopped at spec approval (a security tag), would have stopped at
# an eyes:blocking manual test, and again at production-push (a client's LVI-025).
#
# The lane is that per-artifact statement, and it has two halves that are
# deliberately owned by different parties:
#
#   DECLARED by a human, at inception. `lv-bug-new.sh --lane express`,
#   `lv-dep-notify.sh --lane express`, or `lv-lane.sh declare BRF-NNN` for a
#   brief. It writes `> **Lane:** express (declared by <who>, <date>)` into the
#   artifact and a `lane-declare` line into events.log. Refused under
#   LV_UNATTENDED=1: a worker never declares its own work safe.
#
#   CHECKED by this script, mechanically, twice. `precheck` reads the request
#   text at filing and only warns. `check` reads the WRITTEN PLAN at spec,
#   before any gate would open, and is the one that counts. It is re-run by
#   every consumer rather than trusted from a file, so a plan amended after its
#   check is judged as it now reads.
#
# A pass lets four gates be answered for this plan only, each logged as an
# `autonomy-use` line starting `express:`:
#
#   spec-approval   `answer PLN spec-approval` — /lv-spec routes to ready
#   manual-test     `answer PLN manual-test` — open eyes criteria are ticked and
#                   moved to a `## Post-ship checklist` in plan.md, non-blocking
#   production-push `push-covered` — read by lv-autonomy.sh production-push: a
#                   one-shot push for a main whose every code commit belongs to a
#                   lane-cleared plan, counted against max_unattended_per_day
#   deploy-deferred-criteria
#                   `deferred-covered` — read by /lv-deploy step 4a: the batch's
#                   open deferred rows are all (external)/(soak) criteria of
#                   plans that hold the lane. A plan holds it with such
#                   criteria only when a human accepted its `criteria:` warning
#                   — read them and said they are checked after the deploy
#
# A fail downgrades the plan to the normal lane: the reasons are written into
# plan.md's `## Lane` section and every gate behaves as if no lane existed. A
# human may force it with `check PLN --accept-warnings`, which records the exact
# warnings accepted; a warning that appears later is not covered by it.
#
# NEVER BYPASSED, by construction — the lane answers only the four gates above:
# a worker's needs-input question, the permission baseline, failing tests or a
# verify finding, the consistency pass, deploy-deferred-criteria for an
# `unbuilt` row or a plan outside the lane, and the unattended daily ceiling.
#
# TRUSTED: a declaration made with `--trust` (`--lane trusted` when filing)
# waives every warning the check finds, while the project is pre-launch —
# projectProfile.tier pre-launch and live_from absent or in the future
# (wf_prelaunch, the rule LVI-036 set for production-push). A pre-launch
# project has no users to protect, so a downgrade there only costs the human
# who declared the lane an hour of waiting for the gate they already waived:
# a client's express request for a debug-feedback endpoint stopped at
# spec-approval on its own size, its compose file and its security tag. The
# waived reasons are still found, written into `## Lane` as waived, and logged
# — a reader sees what shipped unseen. Trust is re-read at every check, so
# setting live_from ends it for work already in flight; a live app still
# reading `pre-launch` without a live_from is the case it cannot catch, and
# lv-profile.sh reports that drift. An uncorroborated declaration is never
# trusted, and nothing above under NEVER BYPASSED changes.
#
# WHY THE DECLARATION IS CORROBORATED
#
# The header field is text in a tracked file, and a worker can write text. So a
# declaration counts only when events.log also holds the `lane-declare` line
# this script (or lv-bug-new.sh) wrote at the time, and the latest such line for
# that artifact is not a `lane-clear`. Accepted warnings are corroborated the
# same way. A hand-typed field downgrades, and says why.
#
# ELIGIBILITY (configurable under `lane.express` in levain.yml):
#
#   maxSteps: 5          `### Step` headings under `## Steps`
#   maxFiles: 15         distinct paths on the steps' `**Files:**` lines
#   buildPaths: []       extra globs counted as build/deploy surface
#   contractPaths: []    globs that are a contract shared with another repo
#
#   Disqualifiers: build/deploy surface; auth or route-policy changes; secrets;
#   schema/data migrations or persistent-data paths; a new third-party
#   dependency; the `security` tag or any specApproval.gateTags tag; a contract
#   shared between repos; and (external)/(soak) criteria, which would stop the
#   deploy at deploy-deferred-criteria — a gate the lane never answers. Text is
#   read from `## Goal`, `## Steps` and `## Design Decisions` only.
#
#   A text match is a heuristic and errs toward downgrading: a false positive
#   costs one human gate, a false negative ships unseen.
#
# Exit codes:
#   check / answer   0 express holds · 1 downgraded (reasons on stdout and in
#                    plan.md) · 3 no lane declared · 2 usage or error
#                    · 4 (answer manual-test) a Chrome-Assisted criterion's only
#                    result is a headless ERROR; nothing moved (LVI-043)
#   push-covered     0 covered · 1 not covered (reason on stderr)
#   declare          0 done · 1 refused or error
#   status           0 always, unless the plan cannot be resolved (2)

set -euo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lv-orch-lib.sh
source "$SELF_DIR/lv-orch-lib.sh"

cd "$(wf_develop_root)"   # plans/* and bugs/* are develop-root work

today="${LV_LANE_TODAY:-$(wf_today)}"
EVENTS="$(wf_orch_dir)/events.log"

cmd="${1:-}"
[ $# -gt 0 ] && shift

id=""
gate=""
by=""
clear=false
do_commit=true
accept=false
spend=false
quiet=false
trust=false
range_args=()

while [ $# -gt 0 ]; do
  case "$1" in
    --by)              by="${2:?--by requires a name}"; shift 2 ;;
    --clear)           clear=true; shift ;;
    --no-commit)       do_commit=false; shift ;;
    --accept-warnings) accept=true; shift ;;
    --trust)           trust=true; shift ;;
    --spend)           spend=true; shift ;;
    --quiet)           quiet=true; shift ;;
    --)                shift; range_args=("$@"); break ;;
    -h|--help)         wf_usage; exit 0 ;;
    -*)                wf_bad_option "$1" ;;
    *)  if [ -z "$id" ]; then id="$1"
        elif [ -z "$gate" ]; then gate="$1"
        else echo "Error: unexpected argument '$1'" >&2; exit 2
        fi; shift ;;
  esac
done

say() { $quiet || printf '%s\n' "$*" >&2; }

who_am_i() {
  if [ -n "$by" ]; then printf '%s' "$by"; return; fi
  git config user.name 2>/dev/null || whoami
}

refuse_unattended() {
  if [ "${LV_UNATTENDED:-}" = "1" ]; then
    echo "Error: $1 is a human's statement, and this is an unattended worker (LV_UNATTENDED=1)." >&2
    echo "       A worker never declares its own work safe to ship unseen. Refused." >&2
    exit 1
  fi
}

# ── Artifacts ──────────────────────────────────────────────────────────────

# artifact_file <ID> → the file whose header carries the Lane field.
artifact_file() {
  local a="$1" f slug
  if [[ "$a" =~ ^($LV_BUG_RE)-[0-9]+$ ]]; then
    for f in bugs/open/${a}-*/bug.md bugs/triaged/${a}-*/bug.md bugs/closed/${a}-*/bug.md; do
      [ -f "$f" ] && { printf '%s' "$f"; return 0; }
    done
  elif [[ "$a" =~ ^($LV_BRF_RE)-[0-9]+$ ]]; then
    for f in plans/briefs/${a}-*.md plans/briefs/${a}.md; do
      [ -f "$f" ] && { printf '%s' "$f"; return 0; }
    done
  elif [[ "$a" =~ ^($LV_PLN_RE)-[0-9]+$ ]]; then
    slug=$(wf_registry_field "$a" slug)
    f="plans/${a}-${slug}/plan.md"
    [ -n "$slug" ] && [ -f "$f" ] && { printf '%s' "$f"; return 0; }
  fi
  return 1
}

lane_field() {
  grep -m1 -E '^[ \t]*>?[ \t]*\*\*Lane:\*\*' "$1" 2>/dev/null \
    | sed -E 's/^[ \t]*>?[ \t]*\*\*Lane:\*\*[ \t]*//' || true
}

# set_header_field <file> <line|""> — write, replace or (empty) remove the
# `> **Lane:**` header line. Inserted after the header blockquote, the same
# placement lv-brief-block.sh uses for `Blocked:`.
set_header_field() {
  local file="$1" note="$2"
  LV_NOTE="$note" awk '
    BEGIN { note = ENVIRON["LV_NOTE"]; replaced = 0; last_quote = 0; body = 0 }
    {
      if ($0 ~ /^[ \t]*>?[ \t]*\*\*Lane:\*\*/) {
        if (note != "" && !replaced) { lines[++n] = note; replaced = 1 }
        next
      }
      lines[++n] = $0
      if ($0 ~ /^[ \t]*##[ \t]/) body = 1
      if (!body && $0 ~ /^[ \t]*>/) last_quote = n
    }
    END {
      for (i = 1; i <= n; i++) {
        print lines[i]
        if (note != "" && !replaced && i == last_quote) print note
      }
    }
  ' "$file" > "$file.tmp" && mv "$file.tmp" "$file"
}

# last_event <type-regex> <artifact> → the latest matching events.log line.
last_event() {
  [ -f "$EVENTS" ] || return 0
  awk -F'\t' -v t="$1" -v a="$2" '$2 ~ ("^(" t ")$") && $3 == a { line = $0 } END { if (line != "") print line }' "$EVENTS"
}

# ── The declaration a plan inherits ────────────────────────────────────────
#
# Sets DECL_ID (the artifact the lane was declared on), DECL_TEXT (its field),
# DECL_OK (true when events.log corroborates it) and DECL_NOTE (why not).
resolve_declaration() {
  local plan_md="$1" plan_id="$2" src f v ev
  DECL_ID=""; DECL_TEXT=""; DECL_OK=false; DECL_NOTE=""; DECL_TRUSTED=false

  local candidates=("$plan_id")
  while IFS= read -r src; do
    [ -n "$src" ] && candidates+=("$src")
  # Only the header's Bug/Brief lines (above the first `## `), and only the
  # FIRST id on each: a later id, or one in Goal or Design Decisions, is prose.
  # Reading more gave a client's PLN-092 an express lane declared on an
  # unrelated BUG-089 its prose mentioned (LVI-030).
  done < <(awk '/^## / { exit } { print }' "$plan_md" 2>/dev/null \
             | grep -E '^[ \t]*>?[ \t]*\*\*(Bug|Brief):\*\*' \
             | while IFS= read -r l; do
                 printf '%s\n' "$l" | grep -oE "(($LV_BUG_RE)|($LV_BRF_RE))-[0-9]+" | head -1
               done | awk '!seen[$0]++' || true)

  # A field with no event at all is not a declaration, but it does not hide
  # one: /lv-spec copies the source's `> **Lane:**` line into plan.md, and
  # stopping at that uncorroborated copy refused PLN-002 the lane a human had
  # declared on BUG-002 (a client's LVI-001). So keep looking, and report the
  # first uncorroborated field only when no candidate is corroborated. A
  # lane-clear is an answer, and still ends the search.
  local first_id="" first_text="" first_note=""
  for src in "${candidates[@]}"; do
    if [ "$src" = "$plan_id" ]; then f="$plan_md"; else f=$(artifact_file "$src" || true); fi
    [ -n "$f" ] || continue
    v=$(lane_field "$f")
    case "$v" in
      express*) ;;
      *) continue ;;
    esac
    ev=$(last_event 'lane-declare|lane-clear' "$src")
    if [ -z "$ev" ]; then
      if [ -z "$first_id" ]; then
        first_id="$src"; first_text="$v"
        first_note="$src carries a Lane field, but events.log has no lane-declare for it — a declaration nobody made through the harness is not one"
      fi
      continue
    fi
    DECL_ID="$src"; DECL_TEXT="$v"
    if [ "$(printf '%s' "$ev" | cut -f2)" = "lane-clear" ]; then
      DECL_NOTE="$src's lane was cleared ($(printf '%s' "$ev" | cut -f1)) — its Lane field is left over"
    else
      DECL_OK=true
      # Trust is the event's word, not the field's: the field is text a
      # worker can write.
      case "$(printf '%s' "$ev" | cut -f4)" in *"(trusted)"*) DECL_TRUSTED=true ;; esac
    fi
    return 0
  done
  if [ -n "$first_id" ]; then
    DECL_ID="$first_id"; DECL_TEXT="$first_text"; DECL_NOTE="$first_note"
  fi
  return 0
}

# ── What the plan says ─────────────────────────────────────────────────────

# section <file> <heading>... → the bodies of those `## ` sections, in order.
sections() {
  local file="$1"; shift
  local h
  for h in "$@"; do wf_section_body "$file" "$h"; done
}

plan_step_count() {
  wf_section_body "$1" "Steps" | grep -cE '^###[ \t]+Step' || true
}

# ── Rules ──────────────────────────────────────────────────────────────────

BUILD_GLOBS='*Dockerfile* *docker-compose* *compose.yml *compose.yaml .github/workflows/* *.csproj *.fsproj *.vbproj *.sln *.slnx *Directory.Build.props *Directory.Build.targets *fly.toml *Procfile *Makefile *entrypoint* Program.cs */Program.cs Startup.cs */Startup.cs *deploy.sh .gitlab-ci.yml'
DEP_GLOBS='*package.json *package-lock.json *yarn.lock *pnpm-lock.yaml *requirements*.txt *pyproject.toml *go.mod *go.sum *Gemfile *Gemfile.lock *Cargo.toml *Directory.Packages.props *packages.config'
AUTH_GLOBS='*[Aa]uth* *[Pp]olicy* *[Pp]olicies* *[Pp]ermission* *[Ss]ecurity*'
SECRET_GLOBS='*.env *.env.* *[Ss]ecret* *[Cc]redential* *.pem *.key *.pfx'
MIGRATION_GLOBS='*[Mm]igration* *.sql *.db *.sqlite *DbContext* *[Ss]chema*'

TXT_BUILD='github/workflows|dockerfile|docker-compose|fly\.toml|deploy\.yml|entrypoint'
TXT_AUTH='\[Authorize|AllowAnonymous|RequireAuthorization|AddAuthentication|AddAuthorization|Content-Security-Policy|(^|[^a-z])CSP([^a-z]|$)|route[- ]polic|RoutePolicy|(^|[^a-z])OIDC([^a-z]|$)|(^|[^a-z])CORS([^a-z]|$)|SameSite|Set-Cookie'
TXT_SECRET='(^|[^a-z])secrets?([^a-z]|$)|api[ _-]?keys?|secrets-tool|credentials?([^a-z]|$)|private key|(^|[^a-z])\.env([^a-z]|$)|passwords?([^a-z]|$)|connection string'
TXT_MIGRATION='migrations?([^a-z]|$)|alter table|create table|drop table|drop column|schema change|backfill|dbcontext|litestream|sqlite'
TXT_DEP='npm (install|i|add)( |$)|yarn add|pnpm add|dotnet add package|PackageReference|pip install|poetry add|go get|cargo add|gem install|bundle add|(dev)?dependencies"|new (third-party )?dependenc|third-party (package|library|dependenc)'
# `cross-project:<name>` is a bug's Source field, which says where a request came
# from, not that the plan changes anything shared: a plan quoting its own
# provenance was downgraded for it (a client's LVI-050). The bare words still count.
TXT_CONTRACT='lv-dep-notify|shared contract|cross-repo|cross-project([^:a-z]|$)|breaking change|public api|api contract|(^|[^a-z])dependents?:'

REASONS=()   # "key<TAB>message"
add_reason() {
  local key="$1" msg="$2" r
  for r in ${REASONS[@]+"${REASONS[@]}"}; do [ "${r%%$'\t'*}" = "$key" ] && return 0; done
  REASONS+=("$key"$'\t'"$msg")
}

key_of() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -s ' \t' '_' ; }

# match_globs <category> <label> <globs> <files-file>
match_globs() {
  local cat="$1" label="$2" globs="$3" list="$4" p g
  [ -s "$list" ] || return 0
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    for g in $globs; do
      # shellcheck disable=SC2053
      if [[ "$p" == $g ]]; then add_reason "$cat:$p" "$label: \`$p\`"; break; fi
    done
  done < "$list"
}

# match_text <category> <label> <regex> <text-file> [nocode]
#
# Reports the first match that says the plan DOES the thing. A grep for the
# first hit read "plain UI, no secrets, cookies or tokens captured" as a plan
# handling secrets (LVI-034) and "they rely on SameSite=Lax" as a plan changing
# cookie policy (LVI-035). So each match is judged inside its clause, and these
# do not count:
#
#   - a `**Files:**` line. Paths are judged by match_globs; reading them again
#     as text listed the same compose file twice under two keys.
#   - a term governed by a negating determiner: "no", "without", "nor", "zero",
#     "not any", up to one word before it ("no API keys", "without stored
#     credentials"). "never" is deliberately NOT one: "never logs the password"
#     is a plan that handles passwords.
#   - a clause that says the plan relies on the thing, or leaves it alone:
#     "rely on", "relies on", "unchanged", "untouched".
#   - with `nocode`, text inside a code span. Used for the build surface only,
#     where an edit is a file and a file is on a `**Files:**` line; a code span
#     elsewhere is a command the step runs (`docker compose -f … exec`), not a
#     change to the build.
#
# Later matches are still read, so a plan that says "no secrets" in its Goal
# and strips secret values in Step 1 is reported for Step 1. A heuristic, and it
# still errs toward downgrading: only a match that is plainly not-doing is let
# through.
match_text() {
  local cat="$1" label="$2" re="$3" text="$4" mode="${5:-}" hit term excerpt
  hit=$(LV_RE="$re" LV_MODE="$mode" awk '
    BEGIN {
      re = tolower(ENVIRON["LV_RE"]); nocode = (ENVIRON["LV_MODE"] == "nocode")
      neg = "(^|[^a-z])(no|without|nor|zero|not any)[ \t]+([a-z0-9-]+[ \t]+)?$"
      rel = "(^|[^a-z])rel(y|ies|ying|ied)[ \t]+on([^a-z]|$)"
      kept = "(^|[^a-z])(unchanged|untouched)([^a-z]|$)"
    }
    /\*\*Files:\*\*/ { next }
    {
      orig = $0; l = tolower($0)
      if (nocode) {
        t = l; l = ""
        while (match(t, /`[^`]*`/)) {
          pad = ""; for (i = 0; i < RLENGTH; i++) pad = pad " "
          l = l substr(t, 1, RSTART - 1) pad; t = substr(t, RSTART + RLENGTH)
        }
        l = l t
      }
      rest = l; off = 0
      while (match(rest, re) && RLENGTH > 0) {
        s = off + RSTART; len = RLENGTH
        off = off + RSTART + RLENGTH - 1; rest = substr(rest, RSTART + RLENGTH)
        m = substr(l, s, len)
        lead = match(m, /[a-z0-9.\[]/); if (lead == 0) continue
        s = s + lead - 1; m = substr(m, lead)
        sub(/[^a-z0-9.\]]+$/, "", m)
        before = substr(l, 1, s - 1); sub(/.*([.;:()!?]|—)/, "", before)
        after = substr(l, s + length(m)); sub(/([.;:()!?]|—).*/, "", after)
        if (before ~ neg) continue
        if (before ~ rel) continue
        if ((before " " after) ~ kept) continue
        p = s; st = (p > 40) ? p - 40 : 1
        out = substr(orig, st, 100); gsub(/^[ \t>*-]+/, "", out)
        printf "%s\t%s%s%s\n", substr(orig, s, length(m)), ((st > 1) ? "…" : ""), out, ((length(orig) > st + 99) ? "…" : "")
        exit
      }
    }' "$text" 2>/dev/null || true)
  [ -n "$hit" ] || return 0
  term="${hit%%$'\t'*}"; excerpt="${hit#*$'\t'}"
  add_reason "$cat:$(key_of "$term")" "$label: \"$term\" — $excerpt"
}

cfg_globs() { wf_cfg_list "$1" | tr '\n' ' '; }

# evaluate_plan <PLN> <plan.md> — fills REASONS.
evaluate_plan() {
  local plan_id="$1" plan_md="$2" tmp files text steps nfiles max_steps max_files t tags gating
  REASONS=()
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/lv-lane.XXXXXX")
  files="$tmp/files"; text="$tmp/text"
  wf_plan_files "$plan_md" > "$files"
  sections "$plan_md" "Goal" "Steps" "Design Decisions" > "$text"

  max_steps=$(wf_cfg lane.express.maxSteps 5)
  max_files=$(wf_cfg lane.express.maxFiles 15)
  steps=$(plan_step_count "$plan_md")
  nfiles=$(grep -c . "$files" || true)

  if [ "$steps" -eq 0 ]; then
    add_reason "unparsed:steps" "size: no \`### Step\` headings found under \`## Steps\` — a plan that cannot be measured is not small"
  elif [ "$steps" -gt "$max_steps" ]; then
    add_reason "steps:$steps" "size: $steps steps, over the limit of $max_steps (lane.express.maxSteps)"
  fi
  if [ "$nfiles" -eq 0 ]; then
    add_reason "unparsed:files" "size: no paths found on the steps' \`**Files:**\` lines — a plan whose touched files are unknown cannot be checked"
  elif [ "$nfiles" -gt "$max_files" ]; then
    add_reason "files:$nfiles" "size: $nfiles files touched, over the limit of $max_files (lane.express.maxFiles)"
  fi

  match_globs build     "build/deploy surface"         "$BUILD_GLOBS $(cfg_globs lane.express.buildPaths)" "$files"
  match_text  build     "build/deploy surface"         "$TXT_BUILD" "$text" nocode
  match_globs auth      "auth or route policy"         "$AUTH_GLOBS" "$files"
  match_text  auth      "auth or route policy"         "$TXT_AUTH" "$text"
  match_globs secrets   "secrets"                      "$SECRET_GLOBS" "$files"
  match_text  secrets   "secrets"                      "$TXT_SECRET" "$text"
  match_globs migration "schema/data migration or persistent data" "$MIGRATION_GLOBS" "$files"
  match_text  migration "schema/data migration or persistent data" "$TXT_MIGRATION" "$text"
  match_globs dependency "dependency manifest (a new third-party dependency)" "$DEP_GLOBS" "$files"
  match_text  dependency "new third-party dependency"  "$TXT_DEP" "$text"
  match_globs contract  "contract shared with another repo" "$(cfg_globs lane.express.contractPaths)" "$files"
  match_text  contract  "contract shared with another repo" "$TXT_CONTRACT" "$text"

  tags=$(wf_registry_field "$plan_id" tags | tr ',' ' ')
  gating=" security $(wf_cfg_list specApproval.gateTags | tr '\n' ' ') "
  for t in $tags; do
    [ "$t" = "—" ] && continue
    case "$gating" in
      *" $t "*) add_reason "tag:$t" "tag \`$t\`$([ "$t" = security ] && echo ' — security work is never small by declaration' || echo ' is in specApproval.gateTags')" ;;
    esac
  done

  local MANUAL_EXTERNAL=0 MANUAL_SOAK=0
  eval "$("$SELF_DIR/lv-manual-lint.sh" "$plan_id" --counts 2>/dev/null || true)"
  if [ "${MANUAL_EXTERNAL:-0}" -gt 0 ] || [ "${MANUAL_SOAK:-0}" -gt 0 ]; then
    add_reason "criteria:external=${MANUAL_EXTERNAL:-0},soak=${MANUAL_SOAK:-0}" \
      "criteria: ${MANUAL_EXTERNAL:-0} (external) and ${MANUAL_SOAK:-0} (soak) — deferred at test, they would stop the deploy at deploy-deferred-criteria; accepting this warning says they are checked after the deploy, and the lane then answers that gate for them"
  fi
  rm -rf "$tmp"
}

# accepted_keys <PLN> → the keys the latest corroborated lane-accept covers.
accepted_keys() {
  local ev
  ev=$(last_event 'lane-accept' "$1")
  [ -n "$ev" ] || return 0
  printf '%s' "$ev" | cut -f4 | sed -n 's/^.*accepted: //p' | tr ' ' '\n' | grep . || true
}

# verdict <PLN> <plan.md> → sets LANE (express|normal|none), LANE_OPEN (the
# reasons still standing after acceptance), LANE_ACCEPTED (keys accepted),
# LANE_WAIVED (keys a trusted declaration waived) and LANE_TRUST
# (none|active|lapsed).
verdict() {
  local plan_id="$1" plan_md="$2" r k acc
  LANE=none; LANE_OPEN=(); LANE_ACCEPTED=""; LANE_WAIVED=""; LANE_TRUST=none
  resolve_declaration "$plan_md" "$plan_id"
  [ -n "$DECL_ID" ] || return 0
  evaluate_plan "$plan_id" "$plan_md"
  if ! $DECL_OK; then
    LANE=normal; LANE_OPEN=("declaration"$'\t'"declaration: $DECL_NOTE"); return 0
  fi
  acc=$(accepted_keys "$plan_id")
  LANE_ACCEPTED=$(printf '%s' "$acc" | paste -sd' ' -)
  for r in ${REASONS[@]+"${REASONS[@]}"}; do
    k="${r%%$'\t'*}"
    if [ -n "$acc" ] && printf '%s\n' "$acc" | grep -qxF -- "$k"; then continue; fi
    LANE_OPEN+=("$r")
  done
  if $DECL_TRUSTED; then
    if wf_prelaunch; then
      LANE_TRUST=active
      for r in ${LANE_OPEN[@]+"${LANE_OPEN[@]}"}; do LANE_WAIVED="${LANE_WAIVED:+$LANE_WAIVED }${r%%$'\t'*}"; done
      LANE_OPEN=()
    else
      LANE_TRUST=lapsed
    fi
  fi
  if [ "${#LANE_OPEN[@]}" -eq 0 ]; then LANE=express; else LANE=normal; fi
}

# write_lane_section <plan.md> — replace `## Lane` with the verdict just taken.
#
# Appended with no blank line before the heading, and so is `## Post-ship
# checklist` below. The review fingerprint skips both sections, but a separator
# line belongs to the section BEFORE the heading — and on a plan that ends in
# `## Amendments` that section is hashed, so one blank line made every lane
# check void the review it was checking (LVI-032/033). A blank line already
# there was hashed when the review was stamped, and stays.
write_lane_section() {
  local plan_md="$1" body r
  body="## Lane"$'\n'
  body+="> **Declared:** ${DECL_TEXT} — on ${DECL_ID}"$'\n'
  if [ "$LANE" = express ]; then
    local with=""
    [ -z "$LANE_ACCEPTED" ] || with=' with accepted warnings'
    [ -z "$LANE_WAIVED" ] || with="${with:+$with and} with warnings waived by a trusted declaration"
    body+="> **Checked:** ${today} — **express** — eligible${with}"$'\n'
  else
    body+="> **Checked:** ${today} — **downgraded to the normal lane**; every gate applies"$'\n'
    for r in "${LANE_OPEN[@]}"; do body+="> - ${r#*$'\t'}"$'\n'; done
    [ "$LANE_TRUST" != lapsed ] || body+="> **Trust lapsed:** declared trusted, but the project is no longer pre-launch (projectProfile) — its warnings count"$'\n'
  fi
  if [ -n "$LANE_WAIVED" ]; then
    body+="> **Waived (trusted, pre-launch):** ${LANE_WAIVED}"$'\n'
    for r in "${REASONS[@]}"; do
      case " $LANE_WAIVED " in *" ${r%%$'\t'*} "*) body+="> - ${r#*$'\t'}"$'\n' ;; esac
    done
  fi
  if [ -n "$LANE_ACCEPTED" ]; then
    body+="> **Accepted warnings:** $(last_event lane-accept "$PLAN_ID" | cut -f4 | sed 's/ accepted: .*//') — ${LANE_ACCEPTED}"$'\n'
  fi
  LV_BODY="$body" awk '
    BEGIN { body = ENVIRON["LV_BODY"] }
    /^## / { inside = ($0 ~ /^## Lane([ \t]|$)/) ? 1 : 0
             if (inside && !done) { printf "%s", body; done = 1 } }
    inside { next }
    { print }
    END { if (!done) printf "%s", body }
  ' "$plan_md" > "$plan_md.tmp"
  mv "$plan_md.tmp" "$plan_md"
}

commit_paths() {
  local msg="$1"; shift
  $do_commit || return 0
  if [ -z "$(git status --porcelain -- "$@" 2>/dev/null)" ]; then return 0; fi
  if ! "$SELF_DIR/lv-commit.sh" "$msg" --add "$@" >&2; then
    echo "lv-lane: $* written but could not be committed — commit it before another worker does" >&2
    return 1
  fi
}

resolve_plan() {
  PLAN_ID=$(printf '%s' "$id" | grep -oE "^($LV_PLN_RE)-[0-9]+" || true)
  [ -n "$PLAN_ID" ] || { echo "Error: '$id' is not a $LV_PLN-NNN id" >&2; exit 2; }
  PLAN_MD=$(artifact_file "$PLAN_ID" || true)
  [ -n "$PLAN_MD" ] || { echo "Error: no plan.md for $PLAN_ID (not in the registry, or no folder)" >&2; exit 2; }
}

print_verdict() {
  local r
  if [ "$LANE" = none ]; then
    echo "$PLAN_ID: no lane declared — normal lane."
    return
  fi
  echo "$PLAN_ID: express lane declared on $DECL_ID ($DECL_TEXT)"
  if [ "$LANE" = express ]; then
    echo "  eligible${LANE_ACCEPTED:+ — accepted warnings: $LANE_ACCEPTED}"
    [ -z "$LANE_WAIVED" ] || echo "  trusted, pre-launch — waived: $LANE_WAIVED"
  else
    for r in "${LANE_OPEN[@]}"; do echo "  ✗ ${r#*$'\t'}"; done
    [ "$LANE_TRUST" != lapsed ] || echo "  (declared trusted, but the project is no longer pre-launch — trust lapsed)"
    echo "  → downgraded to the normal lane. Every gate applies."
    echo "    A human may force it: lv-lane.sh check $PLAN_ID --accept-warnings"
  fi
}

# ── Commands ───────────────────────────────────────────────────────────────

case "$cmd" in

declare)
  [ -n "$id" ] || { echo "Usage: $0 declare <$LV_BUG|$LV_BRF|$LV_PLN-NNN> [--trust] [--by <who>] [--clear]" >&2; exit 1; }
  refuse_unattended "Declaring the express lane"
  file=$(artifact_file "$id" || true)
  [ -n "$file" ] || { echo "Error: no artifact file for '$id'" >&2; exit 1; }
  if $clear; then
    set_header_field "$file" ""
    wf_event lane-clear "$id" "express lane cleared by $(who_am_i)"
    commit_paths "lane($id): express lane cleared" "$file"
    echo "$id: express lane cleared — normal lane."
    exit 0
  fi
  who=$(who_am_i)
  kind=express; tag=""
  if $trust; then
    if wf_prelaunch; then
      kind="express, trusted"; tag=" (trusted)"
    else
      echo "$id: --trust ignored — the project is not pre-launch (projectProfile.tier / live_from). Declared plain express." >&2
    fi
  fi
  set_header_field "$file" "> **Lane:** $kind (declared by $who, $today)"
  wf_event lane-declare "$id" "express declared by $who$tag"
  commit_paths "lane($id): $kind lane declared by $who" "$file"
  echo "$id: $kind lane declared by $who."
  if ! [[ "$id" =~ ^($LV_PLN_RE)- ]]; then
    "$0" precheck "$id" || true
  fi
  exit 0
  ;;

precheck)
  [ -n "$id" ] || { echo "Usage: $0 precheck <$LV_BUG|$LV_BRF-NNN>" >&2; exit 2; }
  file=$(artifact_file "$id" || true)
  [ -n "$file" ] || { echo "Error: no artifact file for '$id'" >&2; exit 2; }
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/lv-lane.XXXXXX")
  grep -v -E '^[ \t]*>?[ \t]*\*\*(Lane|Source|Links|Plan):\*\*' "$file" > "$tmp/text" || true
  grep -oE '`[^` ]+`' "$tmp/text" | tr -d '`' | awk '!s[$0]++' > "$tmp/files" || true
  REASONS=()
  match_globs build     "build/deploy surface" "$BUILD_GLOBS $(cfg_globs lane.express.buildPaths)" "$tmp/files"
  match_text  build     "build/deploy surface" "$TXT_BUILD" "$tmp/text" nocode
  match_globs auth      "auth or route policy" "$AUTH_GLOBS" "$tmp/files"
  match_text  auth      "auth or route policy" "$TXT_AUTH" "$tmp/text"
  match_text  secrets   "secrets"              "$TXT_SECRET" "$tmp/text"
  match_text  migration "schema/data migration or persistent data" "$TXT_MIGRATION" "$tmp/text"
  match_globs dependency "dependency manifest" "$DEP_GLOBS" "$tmp/files"
  match_text  dependency "new third-party dependency" "$TXT_DEP" "$tmp/text"
  match_text  contract  "contract shared with another repo" "$TXT_CONTRACT" "$tmp/text"
  rm -rf "$tmp"
  if [ "${#REASONS[@]}" -eq 0 ]; then
    echo "$id: pre-check found nothing that rules the express lane out. The written plan is checked again at spec, and that check is the one that counts." >&2
  else
    {
      echo "$id: pre-check WARNING — the request text suggests this may not stay in the express lane:"
      for r in "${REASONS[@]}"; do echo "  ! ${r#*$'\t'}"; done
      echo "  The lane stays declared. The written plan is checked at spec, and downgrades there with reasons if these hold."
    } >&2
  fi
  exit 0
  ;;

check)
  resolve_plan
  if $accept; then
    refuse_unattended "Accepting express-lane warnings"
    verdict "$PLAN_ID" "$PLAN_MD"
    [ "$LANE" != none ] || { echo "$PLAN_ID: no lane declared — nothing to accept." >&2; exit 3; }
    if [ "$LANE" = express ]; then
      print_verdict; echo "  nothing to accept."
    else
      if [ "${LANE_OPEN[0]%%$'\t'*}" = declaration ]; then
        echo "Error: the declaration itself is not corroborated — $DECL_NOTE" >&2
        echo "       Re-declare it: lv-lane.sh declare $DECL_ID" >&2
        exit 1
      fi
      keys=""
      for r in ${REASONS[@]+"${REASONS[@]}"}; do keys="${keys:+$keys }${r%%$'\t'*}"; done
      wf_event lane-accept "$PLAN_ID" "$(who_am_i) accepted: $keys"
      echo "$PLAN_ID: $(who_am_i) accepted ${#REASONS[@]} warning(s): $keys"
    fi
  fi
  verdict "$PLAN_ID" "$PLAN_MD"
  if [ "$LANE" = none ]; then print_verdict; exit 3; fi
  write_lane_section "$PLAN_MD"
  wf_event lane-check "$PLAN_ID" "express lane $([ "$LANE" = express ] && echo eligible || echo "downgraded: ${#LANE_OPEN[@]} reason(s)")"
  commit_paths "lane($PLAN_ID): express lane $([ "$LANE" = express ] && echo eligible || echo downgraded)" "$PLAN_MD"
  print_verdict
  [ "$LANE" = express ] && exit 0
  exit 1
  ;;

status)
  resolve_plan
  verdict "$PLAN_ID" "$PLAN_MD"
  reasons=""
  for r in ${LANE_OPEN[@]+"${LANE_OPEN[@]}"}; do reasons="${reasons:+$reasons; }${r#*$'\t'}"; done
  wf_emit LANE          "$LANE"
  wf_emit LANE_DECLARED_ON "$DECL_ID"
  wf_emit LANE_DECLARED "$DECL_TEXT"
  wf_emit LANE_REASONS  "$reasons"
  wf_emit LANE_ACCEPTED "$LANE_ACCEPTED"
  wf_emit LANE_WAIVED   "$LANE_WAIVED"
  wf_emit LANE_TRUST    "$LANE_TRUST"
  exit 0
  ;;

answer)
  resolve_plan
  case "$gate" in
    spec-approval|manual-test) ;;
    *) echo "Usage: $0 answer <$LV_PLN-NNN> spec-approval|manual-test" >&2; exit 2 ;;
  esac
  verdict "$PLAN_ID" "$PLAN_MD"
  # Pre-launch answers manual-test for every plan, lane or none: its eyes
  # criteria are checked against the end state (a client's LVI-034,
  # lv-manual-gate.sh PRELAUNCH). The express lane still answers first when it
  # holds, so its record is the one a cleared plan keeps.
  by="the express lane"
  if [ "$gate" = manual-test ] && [ "$LANE" != express ] && wf_prelaunch; then
    by="pre-launch (end-state review)"
  else
    if [ "$LANE" = none ]; then exit 3; fi
    write_lane_section "$PLAN_MD"
    if [ "$LANE" != express ]; then
      commit_paths "lane($PLAN_ID): express lane downgraded" "$PLAN_MD"
      print_verdict
      wf_event lane-check "$PLAN_ID" "express lane downgraded: ${#LANE_OPEN[@]} reason(s) — $gate not answered"
      exit 1
    fi
  fi

  if [ "$gate" = spec-approval ]; then
    commit_paths "lane($PLAN_ID): spec-approval answered by the express lane" "$PLAN_MD"
    wf_event autonomy-use "$PLAN_ID" "express: spec-approval answered by the express lane ($DECL_TEXT, on $DECL_ID)"
    echo "$PLAN_ID: spec-approval answered by the express lane ($DECL_TEXT). Route draft → ready."
    exit 0
  fi

  # And every live Chrome-Assisted criterion with no PASS on record. The guard
  # does not count them, so --open never lists them, and the gate had just told
  # the human they "go to the end-state review too": two stayed unchecked in
  # plan.md and the plan completed with them in neither place (a client's
  # LVI-036). Matched as lv-manual-gate.sh matches rows: normalised, or one
  # containing the other at 24+ characters.
  chrome=""
  live_c=$("$SELF_DIR/lv-manual-lint.sh" "$PLAN_ID" --live 2>/dev/null | awk -F'\t' '$2 == "Chrome-Assisted" { print $5 }' || true)
  if [ -n "$live_c" ]; then
    passes=$(wf_test_progress_passes "$(dirname "$PLAN_MD")/test-progress.md" 2>/dev/null || true)
    chrome=$(LV_LIVE="$live_c" LV_PASS="$passes" LV_PROGRESS="$(dirname "$PLAN_MD")/test-progress.md" awk '
      function norm(s,   t) {
        t = tolower(s); gsub(/[`*_]/, "", t)
        sub(/^[[:space:]]*-[[:space:]]*\[[ xX]\][[:space:]]*/, "", t)
        sub(/^[[:space:]]*\([^)]*\)[[:space:]]*/, "", t)
        gsub(/[[:space:]]+/, " ", t); sub(/^ /, "", t); sub(/ $/, "", t)
        sub(/[.,;:]+$/, "", t)
        return t
      }
      function passed(n,   k) {
        if (n in P) return 1
        for (k in P) if (length(n) >= 24 && length(k) >= 24 && (index(k, n) || index(n, k))) return 1
        return 0
      }
      # Its only result is a headless ERROR: no run produced anything, so it is
      # not moved as untested-but-checked-later. LVI-043 from the coordinator:
      # a sign-in criterion went to the checklist that way, and shipped.
      function errored(n,   k, t, l) {
        t = ""
        if (n in NOTE) t = NOTE[n]
        else for (k in NOTE) if (length(n) >= 24 && length(k) >= 24 && (index(k, n) || index(n, k))) { t = NOTE[k]; break }
        if (t !~ /ERROR/) return 0
        l = tolower(t)
        if (l ~ /disagree/ || (l ~ /ambiguous/ && l ~ /headless|screenshot/)) return 0
        if (l ~ /needs: *(data|oauth|device|extension|profile)/) return 0
        return 1
      }
      BEGIN {
        n = split(ENVIRON["LV_LIVE"], a, "\n"); for (i = 1; i <= n; i++) if (a[i] != "") L[norm(a[i])] = 1
        n = split(ENVIRON["LV_PASS"], a, "\n"); for (i = 1; i <= n; i++) if (a[i] != "") P[norm(a[i])] = 1
        f = ENVIRON["LV_PROGRESS"]
        while ((getline row < f) > 0) {
          m = split(row, c, "|"); if (m < 6) continue
          r = toupper(c[5]); gsub(/[[:space:]]/, "", r)
          if (r == "PASS" || r == "FAIL") continue
          NOTE[norm(c[3])] = c[6]
        }
      }
      /^####[[:space:]]*Chrome-Assisted/ { in_c = 1; next }
      /^#+[[:space:]]/ { in_c = 0 }
      in_c && /^[[:space:]]*-[[:space:]]*\[ \]/ {
        k = norm($0)
        if ((k in L) && !passed(k)) { t = $0; sub(/^[[:space:]]*-[[:space:]]*\[ \][[:space:]]*/, "", t); print (errored(k) ? "E" : "M") "\t" NR "\t" t }
      }
    ' "$PLAN_MD")
  fi
  errored=$(printf '%s\n' "${chrome:-}" | sed -n 's/^E	[0-9]*	//p')
  if [ -n "$errored" ]; then
    echo "$PLAN_ID: manual-test not answered — these Chrome-Assisted criteria have only a headless ERROR," >&2
    echo "  which is no result, so they cannot go to the post-ship checklist as if tested (LVI-043):" >&2
    printf '%s\n' "$errored" | sed 's/^/    - /' >&2
    echo "  Re-run them in /lv-test step 3c (a navigating submit waits now; waitForURL names its landing)," >&2
    echo "  record a PASS, FAIL or needs: reason, or let a human check them at manual-test. Nothing was changed." >&2
    exit 4
  fi
  # manual-test: every open criterion the completion guard would refuse on is
  # ticked and listed under `## Post-ship checklist`, for a human after ship.
  open=$("$SELF_DIR/lv-manual-lint.sh" "$PLAN_ID" --open 2>/dev/null || true)
  moved=0
  list=""
  if [ -n "$open" ]; then
    while IFS=$'\t' read -r ln tag crit _; do
      [ -n "$ln" ] || continue
      sed -i.bak "${ln}s/\[ \]/[x]/" "$PLAN_MD" && rm -f "$PLAN_MD.bak"
      list+="- [ ] ${crit} _(${tag}; shipped without eyes by ${by}, ${today})_"$'\n'
      moved=$((moved + 1))
    done <<< "$open"
  fi
  if [ -n "${chrome:-}" ]; then
    while IFS=$'\t' read -r _kind ln crit; do
      [ -n "$ln" ] || continue
      sed -i.bak "${ln}s/\[ \]/[x]/" "$PLAN_MD" && rm -f "$PLAN_MD.bak"
      list+="- [ ] ${crit} _(chrome-assisted, untested; shipped without eyes by ${by}, ${today})_"$'\n'
      moved=$((moved + 1))
    done <<< "$chrome"
  fi
  if [ -n "${list:-}" ]; then
    LV_LIST="$list" LV_BY="$by" awk '
      BEGIN { list = ENVIRON["LV_LIST"]; by = ENVIRON["LV_BY"] }
      /^## / { if (inside && !done) { printf "%s\n", list; done = 1 }
               inside = ($0 ~ /^## Post-ship checklist([ \t]|$)/) ? 1 : 0 }
      { print }
      END {
        if (inside && !done) { printf "%s", list; done = 1 }
        if (!done) {
          print "## Post-ship checklist"
          print "> Criteria this plan shipped without a human seeing them, because " by
          print "> answered its manual test. Check them after it ships (lv-end-state.sh lists"
          print "> them); a failure is a new bug."
          print ""
          printf "%s", list
        }
      }
    ' "$PLAN_MD" > "$PLAN_MD.tmp" && mv "$PLAN_MD.tmp" "$PLAN_MD"
  fi
  commit_paths "lane($PLAN_ID): manual-test answered by $by — $moved criteria to the post-ship checklist" "$PLAN_MD"
  if [ "$by" = "the express lane" ]; then
    wf_event autonomy-use "$PLAN_ID" "express: manual-test answered by the express lane — $moved criteria moved to the post-ship checklist ($DECL_TEXT)"
  else
    wf_event autonomy-use "$PLAN_ID" "pre-launch: manual-test answered for the end-state review — $moved criteria moved to the post-ship checklist"
  fi
  echo "$PLAN_ID: manual-test answered by $by — $moved criteria moved to the post-ship checklist."
  # A tester that opened the gate also moved the plan to `accept`, which the
  # daemon never dispatches: it waits for /lv-accept. Nothing is left for a
  # human, so hand it back to `testing`, where the next tester takes the
  # all-pass exit (a client's LVI-053 sat in accept until moved by hand).
  if [ "$(wf_registry_field "$PLAN_ID" state)" = accept ]; then
    "$SELF_DIR/lv-registry-update.sh" "$PLAN_ID" accept testing \
      --commit "registry($PLAN_ID): accept → testing — manual-test answered by $by, nothing left for /lv-accept" \
      || echo "lv-lane: $PLAN_ID is still in accept — move it to testing, or the daemon will not pick it up" >&2
  fi
  exit 0
  ;;

budget)
  # What the check will hold the plan to, printed BEFORE the plan is written.
  # /lv-spec step 5c reads it when the source carries a declared lane. A
  # client's PLN-063 was written to 6 steps and 26 files against limits it never
  # saw, and its operator learned at spec-approval that the declared lane had
  # never applied.
  gating=$({ echo security; wf_cfg_list specApproval.gateTags; } | grep . | awk '!seen[$0]++' | tr '\n' ' ' | sed 's/ $//')
  cat <<B
Express lane budget — lv-lane.sh check judges the written plan against this:

  steps   at most $(wf_cfg lane.express.maxSteps 5) \`### Step\` headings under ## Steps   (lane.express.maxSteps)
  files   at most $(wf_cfg lane.express.maxFiles 15) distinct paths on **Files:** lines (lane.express.maxFiles)

Any one of these downgrades it (paths on **Files:** lines, and text in ## Goal, ## Steps, ## Design Decisions):
  - build/deploy surface: $BUILD_GLOBS $(cfg_globs lane.express.buildPaths)
  - auth or route policy: $AUTH_GLOBS, or [Authorize], RequireAuthorization, CSP, CORS, OIDC, SameSite, Set-Cookie
  - secrets: $SECRET_GLOBS, or secrets, API keys, credentials, passwords, connection strings
  - schema/data migration or persistent data: $MIGRATION_GLOBS, or migration, backfill, alter/create/drop table
  - a new third-party dependency: $DEP_GLOBS, or npm install, dotnet add package, PackageReference
  - a contract shared with another repo: $(cfg_globs lane.express.contractPaths)cross-repo, shared contract, public API
  - a tag in: $gating
  - (external) or (soak) criteria, unless a human accepts them

Text that plainly does not do the thing ("no secrets", "relies on SameSite", a command in a
code span) is not counted. Never reword a step to dodge a match: the check is the fail-safe.
B
  exit 0
  ;;

deferred-covered)
  # Does the express lane answer /lv-deploy step 4a's deploy-deferred-criteria
  # for this batch? Yes only when every open row lv-deferred-check.sh reports is
  # an (external) or (soak) criterion of a plan whose lane still holds. A client
  # answered this gate twice in one day, "post-deploy iPad walks, accepted
  # unrun", for plans whose lane had already accepted exactly those criteria.
  #
  # Pre-launch answers it for every plan, lane or none, as it does manual-test:
  # (external) and (soak) rows are checked against the end state, and
  # lv-end-state.sh lists them while they stay open. a client's LVI-042 parked
  # DEPLOY twice in one day on DC-034..036, calibration runs only the operator's
  # terminal can make. (unbuilt) still gates: that is work not done, not a check
  # after shipping.
  prelaunch=0; wf_prelaunch && prelaunch=1
  [ "${#range_args[@]}" -gt 0 ] || { echo "Error: deferred-covered needs -- <git log revision args>" >&2; exit 2; }
  dc_rc=0
  rows=$("$SELF_DIR/lv-deferred-check.sh" --range "${range_args[@]}" 2>/dev/null) || dc_rc=$?
  case "$dc_rc" in
    0) say "express: no open deferred criteria in the batch — not a lane question"; exit 1 ;;
    1) ;;
    *) echo "Error: lv-deferred-check.sh could not read the batch (exit $dc_rc)" >&2; exit 2 ;;
  esac
  dc_file="plans/deferred-criteria.md"
  covered=""
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    dc="${row%% *}"
    id=$(printf '%s' "$row" | sed -nE 's/^[^ ]+ \(([^)]+)\):.*/\1/p')
    tag=$(awk -F'|' -v dc="$dc" '{ i = $2; gsub(/^[ \t]+|[ \t]+$/, "", i) } i == dc { t = $4; gsub(/^[ \t]+|[ \t]+$/, "", t); print t; exit }' "$dc_file")
    case "$tag" in
      external|soak) ;;
      *) say "express: $dc ($id) is a '${tag:-unknown}' criterion — the lane covers (external) and (soak) only"; exit 1 ;;
    esac
    if [ "$prelaunch" = 1 ]; then covered+="$row"$'\n'; continue; fi
    ( resolve_plan ) >/dev/null 2>&1 || { say "express: $dc names $id, which has no plan.md — not covered"; exit 1; }
    resolve_plan
    verdict "$PLAN_ID" "$PLAN_MD"
    [ "$LANE" = express ] || { say "express: $dc belongs to $PLAN_ID, which is not in the express lane ($LANE) — not covered"; exit 1; }
    covered+="$row"$'\n'
  done <<< "$rows"
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    if [ "$prelaunch" = 1 ]; then
      wf_event autonomy-use "$(printf '%s' "$row" | sed -nE 's/^[^ ]+ \(([^)]+)\):.*/\1/p')" \
        "pre-launch: deploy-deferred-criteria answered for the end-state review for ${row%% *} — checked after the deploy"
      continue
    fi
    wf_event autonomy-use "$(printf '%s' "$row" | sed -nE 's/^[^ ]+ \(([^)]+)\):.*/\1/p')" \
      "express: deploy-deferred-criteria answered by the express lane for ${row%% *} — checked after the deploy"
  done <<< "$covered"
  printf '%s' "$covered"
  exit 0
  ;;

push-covered)
  # Is every code commit that `git push origin main` would send the work of a
  # plan the express lane cleared? A push is a batch; the lane is per plan, so
  # the answer is yes only when there is nothing else in the batch.
  main=$(git rev-parse --verify -q refs/heads/main 2>/dev/null || true)
  origin_main=$(git rev-parse --verify -q refs/remotes/origin/main 2>/dev/null || true)
  [ -n "$main" ] && [ -n "$origin_main" ] || { say "express: no main or origin/main — nothing to cover"; exit 1; }
  [ "$main" != "$origin_main" ] || { say "express: main is origin/main — nothing to push"; exit 1; }
  git merge-base --is-ancestor "$origin_main" "$main" 2>/dev/null \
    || { say "express: main does not fast-forward origin/main — not covered"; exit 1; }

  plans=""
  # A merge carries code of its own only when its combined diff is non-empty:
  # a conflict resolution nobody's plan wrote.
  while IFS= read -r m; do
    [ -n "$m" ] || continue
    if [ -n "$(git diff-tree --cc --name-only -r --no-commit-id "$m" -- . ':(exclude)plans' ':(exclude)bugs' 2>/dev/null)" ]; then
      say "express: merge ${m:0:9} resolves code itself — no plan owns it, not covered"; exit 1
    fi
  done < <(git rev-list --merges "$origin_main..$main")
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    [ -n "$(git diff-tree --no-commit-id --name-only -r "$c" -- . ':(exclude)plans' ':(exclude)bugs' 2>/dev/null)" ] || continue
    subj=$(git log -1 --format=%s "$c")
    p=$(printf '%s' "$subj" | grep -oE "\\(($LV_PLN_RE)-[0-9]+" | head -1 | tr -d '(' || true)
    if [ -z "$p" ]; then
      say "express: ${c:0:9} \"$subj\" changes code and names no plan — not covered"; exit 1
    fi
    case " $plans " in *" $p "*) ;; *) plans="${plans:+$plans }$p" ;; esac
  done < <(git rev-list --no-merges "$origin_main..$main")
  [ -n "$plans" ] || { say "express: nothing in origin/main..main changes code — not a lane question"; exit 1; }

  spent_dir="$(wf_orch_dir)/lane"
  for p in $plans; do
    id="$p"; resolve_plan
    [ "$(wf_registry_field "$PLAN_ID" state)" = complete ] \
      || { say "express: $PLAN_ID is not complete — not covered"; exit 1; }
    verdict "$PLAN_ID" "$PLAN_MD"
    [ "$LANE" = express ] || { say "express: $PLAN_ID is not in the express lane ($LANE) — not covered"; exit 1; }
    if [ -f "$spent_dir/$PLAN_ID.pushed" ] && [ "$(cat "$spent_dir/$PLAN_ID.pushed")" != "$main" ]; then
      say "express: $PLAN_ID's one push was spent on $(cut -c1-9 < "$spent_dir/$PLAN_ID.pushed") — not covered"; exit 1
    fi
  done
  if $spend; then
    mkdir -p "$spent_dir"
    for p in $plans; do printf '%s\n' "$main" > "$spent_dir/$p.pushed"; done
  fi
  echo "$plans"
  exit 0
  ;;

*)
  wf_usage >&2
  exit 2
  ;;
esac
