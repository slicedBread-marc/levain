#!/bin/bash
set -euo pipefail

# claude-workflow installer
# Installs the workflow skills, templates, and folder structure into a project.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_DIR="."
INSTALL_COMMIT=true

for arg in "$@"; do
    case "$arg" in
        --no-commit) INSTALL_COMMIT=false ;;
        -*) echo "Unknown option: $arg" >&2; exit 1 ;;
        *)  TARGET_DIR="$arg" ;;
    esac
done
[ "${WF_INSTALL_NO_COMMIT:-0}" = "1" ] && INSTALL_COMMIT=false

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo "claude-workflow installer"
echo "========================"
echo ""

# Check for config
CONFIG_FILE="$TARGET_DIR/claude-workflow.yml"
if [ ! -f "$CONFIG_FILE" ]; then
    echo -e "${YELLOW}No claude-workflow.yml found in $TARGET_DIR${NC}"
    echo "Creating from template..."
    cp "$SCRIPT_DIR/config.example.yml" "$CONFIG_FILE"
    echo -e "${GREEN}Created $CONFIG_FILE — edit it with your project settings, then re-run.${NC}"
    exit 0
fi

# Parse config (simple grep-based, no yq dependency)
get_config() {
    # head -1: a duplicated key would otherwise return a multi-line value, and
    # every consumer feeds these into `sed -e "s|...|$VALUE|"`, where an
    # embedded newline is a syntax error rather than a wrong answer.
    #
    # The value is then UNQUOTED, and a matching pair of single quotes counts as
    # much as a pair of double ones. This stripped `"` only, and every filter
    # example in config.example.yml is single-quoted YAML — it has to be, since
    # the value itself contains double quotes:
    #
    #   test_exclude_e2e: '--ignore-exit-code 8 --filter-not-namespace "*E2E*"'
    #
    # so the rendered skill said `dotnet test '--ignore-exit-code 8 --filter-...'`
    # — two flags fused into ONE shell argument by quotes that were never part
    # of the value. dotnet took it as a single unrecognised token, ran the whole
    # suite unfiltered, and failed on an E2E test the filter existed to exclude
    # (client-a WFI-088, WFI-090, twice on the same plan).
    grep "^$1:" "$CONFIG_FILE" 2>/dev/null | head -1 \
      | sed "s/^$1:[[:space:]]*//" \
      | sed -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'\$/\1/" || true
}

BUILD_CMD=$(get_config "build_command")
TEST_CMD=$(get_config "test_command")
TEST_FILTER=$(get_config "test_filter_flag")
TEST_EXCLUDE_E2E=$(get_config "test_exclude_e2e")
TEST_ONLY_E2E=$(get_config "test_only_e2e")
NAMESPACE_CONV=$(get_config "namespace_convention")
CONVENTIONS_NOTE=$(get_config "conventions_note")
LOCAL_START=$(get_config "local_start_command")
LOCAL_DEPLOY=$(get_config "local_deploy_command")
LOCAL_STOP=$(get_config "local_stop_command")
PROJECT_SLUG=$(get_config "project_slug")
PRODUCTION_LOGS_URL=$(get_config "production_logs_url")
PRODUCTION_URL=$(get_config "production_url")

# project_slug is required as of workflow v1.33.0 — it namespaces Docker
# compose projects so multiple clients can coexist on one Docker daemon.
if [ -z "$PROJECT_SLUG" ]; then
    RED='\033[0;31m'
    echo -e "${RED}ERROR: project_slug is required (introduced in workflow v1.33.0).${NC}"
    echo ""
    echo "Edit $CONFIG_FILE and set project_slug to a short identifier"
    echo "unique to this project (e.g., the repo directory name):"
    echo ""
    echo "    project_slug: \"$(basename "$(cd "$TARGET_DIR" && pwd)")\""
    echo ""
    echo "This namespaces Docker compose projects (e.g., <slug>-pln004) so"
    echo "multiple clients on one machine don't collide on container names."
    exit 1
fi

# Read source_dirs as comma-separated string
SOURCE_DIRS=$(grep -A 10 "^source_dirs:" "$CONFIG_FILE" | grep "^  - " | sed 's/^  - //' | sed 's/"//g' | tr '\n' ', ' | sed 's/,$//')

# Backfill config blocks for clients installed before they existed. Without
# this the feature silently runs on hardcoded defaults and there is nothing in
# the config to discover — including no visible flag to turn it on. Appended
# verbatim from config.example.yml, never overwritten.

# extract_block <comment-header-prefix> — that header through the line before
# the next `# ── ` header (or EOF).
extract_block() {
    awk -v start="$1" '
      index($0, start) == 1 { on = 1; print; next }
      on && /^# ── / { exit }
      on { print }
    ' "$SCRIPT_DIR/config.example.yml"
}

if ! grep -q "^orchestrator:" "$CONFIG_FILE" 2>/dev/null; then
    awk '/^# ── Orchestrator ─/,0' "$SCRIPT_DIR/config.example.yml" >> "$CONFIG_FILE"
    echo -e "${GREEN}  Added orchestrator: block to $CONFIG_FILE (disabled by default)${NC}"
fi

# The test-account keys existed only in wf-docker-up.sh's source comments, so
# no project ever found them: five clients on 5.2.4, zero hits for
# test_account. The fix for "the tester gets a URL and no account" shipped in
# the library and never reached the config it reads (WFI-074).
if ! grep -q "^test_account_command:" "$CONFIG_FILE" 2>/dev/null; then
    printf '\n' >> "$CONFIG_FILE"
    extract_block "# ── Test account" >> "$CONFIG_FILE"
    echo -e "${GREEN}  Added test_account_command/test_account_note to $CONFIG_FILE (blank — no behavior change)${NC}"
    echo -e "${YELLOW}    Set them if the app needs a login, or a tester gets a URL with no way in${NC}"
fi

# v6.3.1: which changes make a filtered test run untrustworthy. Empty by default,
# so nothing changes until a project names its shared test state.
if ! grep -q "^testScopeFullSuiteGlobs:" "$CONFIG_FILE" 2>/dev/null; then
    printf '\n' >> "$CONFIG_FILE"
    extract_block "# ── Shared test state" >> "$CONFIG_FILE"
    echo -e "${GREEN}  Added testScopeFullSuiteGlobs to $CONFIG_FILE (empty — no behavior change)${NC}"
    echo -e "${YELLOW}    Fill it in if your tests share fixtures; a filtered run cannot see ordering bugs${NC}"
fi

# v3.0: manual-test gating keys on the surface the diff touches, not on how
# many `#### Manual` criteria the planner wrote. Absent, wf-manual-gate.sh
# falls back to pre-3.0 behavior (stop whenever anything manual remains).
if ! grep -q "^manualTestGate:" "$CONFIG_FILE" 2>/dev/null; then
    printf '\n' >> "$CONFIG_FILE"
    extract_block "# ── Manual-test gate" >> "$CONFIG_FILE"
    echo -e "${GREEN}  Added manualTestGate: block to $CONFIG_FILE${NC}"
    echo -e "${YELLOW}    Review renderingSurfaces — the defaults assume a .NET/Razor layout${NC}"
fi

# v3.0: who approves a spec. Ships as `gate` — today's behavior — so nothing
# changes for an existing client until they opt in.
if ! grep -q "^specApproval:" "$CONFIG_FILE" 2>/dev/null; then
    printf '\n' >> "$CONFIG_FILE"
    extract_block "# ── Spec approval" >> "$CONFIG_FILE"
    echo -e "${GREEN}  Added specApproval: block to $CONFIG_FILE (mode: gate — unchanged behavior)${NC}"
fi

# The orchestrator's consistency keys default to on in the scripts, so an older
# orchestrator block needs no edit — but say so rather than letting a new role
# appear in the board unannounced.
if grep -q "^orchestrator:" "$CONFIG_FILE" 2>/dev/null && ! grep -q "consistency_pass:" "$CONFIG_FILE" 2>/dev/null; then
    echo -e "${YELLOW}  Note: the cross-plan consistency pass is ON by default (no config key present).${NC}"
    echo -e "${YELLOW}    Add 'consistency_pass: false' under orchestrator: to disable it.${NC}"
fi

if grep -qE "^autoTestGrowth:" "$CONFIG_FILE" 2>/dev/null && \
   awk '/^autoTestGrowth:/{f=1;next} f && /^[a-zA-Z]/{exit} f && /enabled:[[:space:]]*false/{found=1} END{exit !found}' "$CONFIG_FILE"; then
    echo -e "${YELLOW}  Note: autoTestGrowth.enabled is false here; it now defaults to true upstream.${NC}"
    echo -e "${YELLOW}    A criterion checked once by a human is not a regression test — consider enabling it.${NC}"
fi

echo "Configuration:"
echo "  Build:       $BUILD_CMD"
echo "  Test:        $TEST_CMD"
echo "  Source dirs: $SOURCE_DIRS"
echo ""

# Create folder structure
#
# plans/briefs/ and the bug folders, and nothing else. The state folders this
# used to create — drafts/ ready/ active/ verify/ replanning/ complete/
# rolled-back/ — are from the pre-registry model, where a plan's state was its
# location. Since v3.2.0 a plan lives at plans/PLN-NNN-<slug>/ forever and its
# state is a column in REGISTRY.md (Design Principle 1: immovable plans).
# Nothing reads these paths; creating them in every client puts the old model
# back on screen for anyone browsing the repo.
echo "Creating folder structure..."
mkdir -p "$TARGET_DIR/plans/briefs"
echo -e "${GREEN}  plans/ folder structure created${NC}"

# Seed REGISTRY.md if it doesn't exist — never overwrite live state
REGISTRY_TEMPLATE="$SCRIPT_DIR/templates/plans/REGISTRY.md"
REGISTRY_DEST="$TARGET_DIR/plans/REGISTRY.md"
if [ -f "$REGISTRY_TEMPLATE" ] && [ ! -f "$REGISTRY_DEST" ]; then
    mkdir -p "$TARGET_DIR/plans"
    cp "$REGISTRY_TEMPLATE" "$REGISTRY_DEST"
    echo -e "${GREEN}  Seeded plans/REGISTRY.md from template${NC}"
else
    echo -e "${YELLOW}  plans/REGISTRY.md already exists — skipping${NC}"
    # v2.00 migration: ensure REGISTRY has the WF column. Row layout is
    # "| ID | Slug | State | Priority | Branch | Updated | WF |" — 7 data
    # columns means 8 pipes. Rows with 7 pipes lack WF; append an empty
    # WF cell so the dispatcher routes them to v1.x (legacy baseline).
    header_line=$(grep -nE '^\| ID \|' "$REGISTRY_DEST" | head -1 | cut -d: -f1 || true)
    if [ -n "$header_line" ] && ! grep -qE '^\| ID \|.*\| WF \|' "$REGISTRY_DEST"; then
        echo "  Migrating REGISTRY.md → adding WF column (legacy rows → v1.x)"
        # Header + separator lines get " WF |" appended
        awk 'BEGIN{OFS=""}
             NR==FNR{if(/^\| ID \|/){hdr=NR}; if(hdr && NR==hdr+1){sep=NR}; next}
             {
               if(FNR==hdr){sub(/\|[[:space:]]*$/, "| WF |"); print; next}
               if(FNR==sep){sub(/\|[[:space:]]*$/, "|-|"); print; next}
               # Data rows start with "| PLN-" and end with " |"
               if(/^\| PLN-/){sub(/\|[[:space:]]*$/, "|  |"); print; next}
               print
             }' "$REGISTRY_DEST" "$REGISTRY_DEST" > "$REGISTRY_DEST.tmp" && mv "$REGISTRY_DEST.tmp" "$REGISTRY_DEST"
        echo -e "${GREEN}  REGISTRY.md migrated (WF column added)${NC}"
    fi

    # v5 migration: Tags and Deps. The seeded header shipped 7 columns while
    # wf-spec was already writing 9-field rows, so header and rows disagreed
    # from the first plan onwards — wf-set-tags.sh patched it per row, which
    # hid the mismatch instead of fixing it.
    if grep -qE '^\| ID \|.*\| WF \|' "$REGISTRY_DEST" && ! grep -qE '^\| ID \|.*\| Tags \|' "$REGISTRY_DEST"; then
        echo "  Migrating REGISTRY.md → adding Tags and Deps columns"
        awk 'BEGIN{OFS=""}
             NR==FNR{if(/^\| ID \|/){hdr=NR}; if(hdr && NR==hdr+1){sep=NR}; next}
             {
               if(FNR==hdr){sub(/\|[[:space:]]*$/, "| Tags | Deps |"); print; next}
               if(FNR==sep){sub(/\|[[:space:]]*$/, "|-|-|"); print; next}
               # Only pad rows that are still 7-field; wf-set-tags.sh may
               # already have widened some of them.
               if(/^\| (PLN|BUG|BRF)-/){
                 n=gsub(/\|/,"|"); if(n==8){sub(/\|[[:space:]]*$/, "| — | — |")}
                 print; next
               }
               print
             }' "$REGISTRY_DEST" "$REGISTRY_DEST" > "$REGISTRY_DEST.tmp" && mv "$REGISTRY_DEST.tmp" "$REGISTRY_DEST"
        echo -e "${GREEN}  REGISTRY.md migrated (Tags/Deps columns added)${NC}"
    fi
fi

# Copy and templatize plan templates
echo "Installing templates..."
for f in "$SCRIPT_DIR/templates/plans/TEMPLATE.md" "$SCRIPT_DIR/templates/plans/briefs/TEMPLATE.md" "$SCRIPT_DIR/templates/plans/briefs/INDEX.md"; do
    DEST="$TARGET_DIR/plans/${f#$SCRIPT_DIR/templates/plans/}"

    # v6 migration: the plan template carries the schema. A client left on the
    # v5 template keeps drafting untagged `#### Manual` criteria, which the
    # verify lint then fails back to draft — so this one is replaced rather
    # than skipped. The old file is kept beside it; local edits are not lost,
    # they just stop being the template.
    REPLACING=false
    if [ "$(basename "$f")" = "TEMPLATE.md" ] && [ "$(dirname "$f")" = "$SCRIPT_DIR/templates/plans" ] \
       && [ -f "$DEST" ] && ! grep -q 'schema_version:\*\* 6' "$DEST" 2>/dev/null; then
        REPLACING=true
    fi

    if [ -f "$DEST" ] && [ "$REPLACING" = false ]; then
        echo -e "  ${YELLOW}Skipping $DEST (already exists)${NC}"
    else
        mkdir -p "$(dirname "$DEST")"
        # Render to a temp file and swap. The v6 replacement below removes a
        # file the client is using, so a failed render must not be able to
        # leave them with no template at all.
        sed -e "s|{{build_command}}|$BUILD_CMD|g" \
            -e "s|{{test_command}}|$TEST_CMD|g" \
            -e "s|{{test_filter_flag}}|$TEST_FILTER|g" \
            -e "s|{{test_exclude_e2e}}|$TEST_EXCLUDE_E2E|g" \
            -e "s|{{test_only_e2e}}|$TEST_ONLY_E2E|g" \
            -e "s|{{namespace_convention}}|$NAMESPACE_CONV|g" \
            -e "s|{{conventions_note}}|$CONVENTIONS_NOTE|g" \
            -e "s|{{source_dirs}}|$SOURCE_DIRS|g" \
            -e "s|{{project_slug}}|$PROJECT_SLUG|g" \
            -e "s|{{production_logs_url}}|$PRODUCTION_LOGS_URL|g" \
            -e "s|{{production_url}}|$PRODUCTION_URL|g" \
            "$f" > "$DEST.new"

        if [ "$REPLACING" = true ]; then
            # Keep a copy only when git isn't already keeping one. plans/ is
            # tracked in every client, so for a committed template the previous
            # version is `git show HEAD:plans/TEMPLATE.md` away — and a .bak
            # beside it is worse than redundant: it is an untracked file in a
            # tracked directory that nothing ever removes, so the tree is dirty
            # forever and `deploy && status --porcelain` can never come back
            # empty. app and client-i both carry one from the v6 upgrade.
            if git -C "$TARGET_DIR" ls-files --error-unmatch "plans/TEMPLATE.md" >/dev/null 2>&1; then
                rm -f "$DEST"
                echo -e "${YELLOW}  plans/TEMPLATE.md is pre-v6 — replacing (previous version: git show HEAD:plans/TEMPLATE.md)${NC}"
            else
                mv "$DEST" "$DEST.v5.bak"
                echo -e "${YELLOW}  plans/TEMPLATE.md is pre-v6 — replacing (untracked, so the old copy is kept at TEMPLATE.md.v5.bak)${NC}"
            fi
        fi
        mv "$DEST.new" "$DEST"
        echo -e "${GREEN}  Installed $DEST${NC}"
    fi
done

# Copy and templatize skills
echo "Installing skills..."
mkdir -p "$TARGET_DIR/.claude/skills"
for skill_dir in "$SCRIPT_DIR/skills"/*/; do
    SKILL_NAME=$(basename "$skill_dir")
    DEST_DIR="$TARGET_DIR/.claude/skills/$SKILL_NAME"
    mkdir -p "$DEST_DIR"

    sed -e "s|{{build_command}}|$BUILD_CMD|g" \
        -e "s|{{test_command}}|$TEST_CMD|g" \
        -e "s|{{test_filter_flag}}|$TEST_FILTER|g" \
        -e "s|{{test_exclude_e2e}}|$TEST_EXCLUDE_E2E|g" \
        -e "s|{{test_only_e2e}}|$TEST_ONLY_E2E|g" \
        -e "s|{{namespace_convention}}|$NAMESPACE_CONV|g" \
        -e "s|{{conventions_note}}|$CONVENTIONS_NOTE|g" \
        -e "s|{{source_dirs}}|$SOURCE_DIRS|g" \
        -e "s|{{project_slug}}|$PROJECT_SLUG|g" \
        -e "s|{{production_logs_url}}|$PRODUCTION_LOGS_URL|g" \
        -e "s|{{production_url}}|$PRODUCTION_URL|g" \
        "$skill_dir/SKILL.md" > "$DEST_DIR/SKILL.md"

    echo -e "${GREEN}  Installed /$(basename "$skill_dir")${NC}"
done

# Install local env script (only if local_deploy_command is set)
if [ -n "$LOCAL_DEPLOY" ]; then
    sed -e "s|{{local_start_command}}|$LOCAL_START|g" \
        -e "s|{{local_deploy_command}}|$LOCAL_DEPLOY|g" \
        -e "s|{{local_stop_command}}|$LOCAL_STOP|g" \
        -e "s|{{project_slug}}|$PROJECT_SLUG|g" \
        "$SCRIPT_DIR/templates/on-implement-commit.sh" > "$TARGET_DIR/.claude/on-implement-commit.sh"
    chmod +x "$TARGET_DIR/.claude/on-implement-commit.sh"
    echo -e "${GREEN}  Installed .claude/on-implement-commit.sh${NC}"

    # Gitignore local-env runtime files
    GITIGNORE="$TARGET_DIR/.gitignore"
    for pattern in ".claude/local-env.timestamp" ".claude/local-env.pid" ".claude/local-env.log"; do
        if ! grep -qF "$pattern" "$GITIGNORE" 2>/dev/null; then
            echo "$pattern" >> "$GITIGNORE"
        fi
    done
    echo -e "${GREEN}  Updated .gitignore with local-env runtime files${NC}"
else
    echo -e "${YELLOW}  local_deploy_command not set — skipping local env install${NC}"
fi

# Install verify trigger script (always — verify agent is core to the pipeline)
cp "$SCRIPT_DIR/templates/on-verify-trigger.sh" "$TARGET_DIR/.claude/on-verify-trigger.sh"
chmod +x "$TARGET_DIR/.claude/on-verify-trigger.sh"
echo -e "${GREEN}  Installed .claude/on-verify-trigger.sh${NC}"

# Gitignore verify runtime files
GITIGNORE="$TARGET_DIR/.gitignore"
for pattern in ".claude/verify-*.log" ".claude/verify-*.pid"; do
    if ! grep -qF "$pattern" "$GITIGNORE" 2>/dev/null; then
        echo "$pattern" >> "$GITIGNORE"
    fi
done

HARNESS_IGNORED=0

# Generated workflow harness.
#
# deploy writes these; the library is their source of truth. Tracking them made
# every deploy dirty every client — 253 files across five repos, none written
# by a human — and put a git-managed path under a second, independent writer.
# wf-worktree-sparse.sh states where that leads: "Excluding a file you also
# write is not a stricter policy than tracking it; it is a broken one." The
# same is true of tracking it. See docs/untracked-harness.md.
#
# NOT ignored, deliberately: claude-workflow.yml (the project's own config),
# .claude/workflow-version (the one-line stamp saying which harness a commit
# was made under), WORKFLOW.md (the entry contract), and plans/ + bugs/.
#
# The `wf-` prefix on the skills glob is load-bearing: a project's own skills
# sit in the same directory and are its source, not ours.
for pattern in \
    ".claude/skills/wf-*/" \
    ".claude/workflow.md" \
    ".claude/workflow-source" \
    ".claude/settings.local.json" \
    ".claude/on-implement-commit.sh" \
    ".claude/on-verify-trigger.sh" \
    "scripts/wf-exec.sh" \
    "scripts/version-map.txt" \
    "scripts/wf-prune-versions.sh" \
    "scripts/v*/" ; do
    if ! grep -qxF "$pattern" "$GITIGNORE" 2>/dev/null; then
        echo "$pattern" >> "$GITIGNORE"
        HARNESS_IGNORED=$((HARNESS_IGNORED + 1))
    fi
done
if [ "$HARNESS_IGNORED" -gt 0 ]; then
    echo -e "${GREEN}  Added $HARNESS_IGNORED generated-harness pattern(s) to .gitignore${NC}"
    if git -C "$TARGET_DIR" ls-files --error-unmatch scripts/wf-exec.sh >/dev/null 2>&1; then
        echo -e "${YELLOW}  The harness is still TRACKED here. To finish the migration:${NC}"
        # --ignore-unmatch is not optional: `git rm` is atomic, so a single
        # pathspec matching nothing tracked (a client that already ignores
        # .claude/skills/*, as app did) aborts the WHOLE command and untracks
        # nothing — silently, if stderr is redirected.
        echo "    git rm -r --cached --quiet --ignore-unmatch \\"
        echo "      .claude/skills/wf-* .claude/workflow.md \\"
        echo "      .claude/on-implement-commit.sh .claude/on-verify-trigger.sh \\"
        echo "      scripts/wf-exec.sh scripts/version-map.txt scripts/wf-prune-versions.sh scripts/v*"
        echo "    git commit -m 'chore: stop tracking the generated workflow harness'"
    fi
fi

# Feature worktrees.
#
# `feature-branches/` is the workflow's own convention — wf-worktree-sparse.sh
# creates it — so ignoring it is the harness's job, not each project's. Left
# out, it sits untracked on develop from the moment the first plan gets a
# worktree, and a `git add -A` on develop commits an entire feature worktree
# into the planning branch (WFI-032, same class as WFI-007).
if ! grep -qF "feature-branches/" "$GITIGNORE" 2>/dev/null; then
    echo "feature-branches/" >> "$GITIGNORE"
    echo -e "${GREEN}  Added feature-branches/ to .gitignore${NC}"
fi

# The plan pointer.
#
# `.plan-ref` names which plan a WORKTREE is building. It is per-worktree
# runtime state, not branch content — and it was tracked until v6.0.0, which
# means every merge carried it out of the worktree it described: feature →
# release, release → main, main → develop. client-a's WFI-103 found develop
# tracking a `.plan-ref` reading PLN-015, delivered by that plan's own PR merge.
#
# A tracked pointer on develop is not cosmetic. `git worktree add` materialises
# tracked files, so every NEW worktree starts life pointing at someone else's
# finished plan until step 6 of wf-implement overwrites it — and that overwrite
# then shows as a modification to a tracked file, which the next `git add -u`
# commits and the next merge propagates. The loop feeds itself.
#
# Per docs/worktrees.md this is the gitignored row: the harness generates it,
# and a session reads it off its own disk. wf-implement writes it into the
# worktree; nothing else needs it to exist.
if ! grep -qxF ".plan-ref" "$GITIGNORE" 2>/dev/null; then
    echo ".plan-ref" >> "$GITIGNORE"
    echo -e "${GREEN}  Added .plan-ref to .gitignore${NC}"
fi
# .gitignore does not untrack anything already in the index, so a client that
# tracked it before v6.0.0 keeps propagating it until this is run.
if git -C "$TARGET_DIR" ls-files --error-unmatch .plan-ref >/dev/null 2>&1; then
    echo -e "${YELLOW}  .plan-ref is still TRACKED here — it will keep leaking across merges.${NC}"
    echo -e "${YELLOW}  On develop, run:${NC}"
    echo "    git rm --cached --quiet --ignore-unmatch .plan-ref"
    echo "    git commit -m 'chore: stop tracking .plan-ref (per-worktree state)'"
fi

# Orchestrator runtime dirs — gates, worker logs, events.log, locks.
# All runtime state, none of it belongs in git.
mkdir -p "$TARGET_DIR/.claude/orchestrator/gates" \
         "$TARGET_DIR/.claude/orchestrator/gates/resolved" \
         "$TARGET_DIR/.claude/orchestrator/logs" \
         "$TARGET_DIR/.claude/orchestrator/attempts" \
         "$TARGET_DIR/.claude/orchestrator/claims"
if ! grep -qF ".claude/orchestrator/" "$GITIGNORE" 2>/dev/null; then
    echo ".claude/orchestrator/" >> "$GITIGNORE"
fi
echo -e "${GREEN}  Created .claude/orchestrator/ (gitignored)${NC}"

# Install post-commit hook.
#
# Refresh on CONTENT, not on a feature marker. This used to skip whenever the
# hook already contained "claude-workflow: verify agent trigger" — a one-shot
# migration check from the release that added that trigger. Once a client had
# it, the hook was frozen: every later fix to the template deployed to the one
# client that happened not to have the hook yet, and silently nowhere else.
# The hook is generated infrastructure, like the skills, so the library owns it
# and overwrites it whenever it differs.
HOOK="$TARGET_DIR/.git/hooks/post-commit"
HOOK_SRC="$SCRIPT_DIR/templates/hooks/post-commit"
if [ ! -f "$HOOK" ]; then
    cp "$HOOK_SRC" "$HOOK"
    chmod +x "$HOOK"
    echo -e "${GREEN}  Installed .git/hooks/post-commit${NC}"
elif ! grep -q "claude-workflow" "$HOOK"; then
    # Not ours. Keep it — clobbering a project's own hook is not our call.
    cp "$HOOK" "$HOOK.pre-workflow"
    cp "$HOOK_SRC" "$HOOK"
    chmod +x "$HOOK"
    echo -e "${YELLOW}  Replaced a non-workflow post-commit hook${NC}"
    echo -e "${YELLOW}  The original is at .git/hooks/post-commit.pre-workflow — merge it back if you need it${NC}"
elif cmp -s "$HOOK_SRC" "$HOOK"; then
    echo -e "${YELLOW}  post-commit hook already up to date — skipping${NC}"
else
    cp "$HOOK_SRC" "$HOOK"
    chmod +x "$HOOK"
    echo -e "${GREEN}  Updated .git/hooks/post-commit${NC}"
fi

# Install the Claude Code session hooks (state rehydration after compaction).
#
# These are CLAUDE CODE hooks in .claude/settings.json — a different mechanism
# from the git hook above, and the reason both live here is that they are the
# only two places the harness gets to run without a skill asking it to.
#
# SessionStart(compact) is the load-bearing one: it is the only event whose
# output reaches the MODEL after a compaction. PostCompact's stdout is shown to
# the human and nothing else. See docs/rehydration.md and wf-rehydrate.sh.
#
# settings.json is the client's file, not ours — it may hold their permissions,
# env and their own hooks. So this MERGES rather than overwriting; the rules are
# in templates/hooks/settings-merge.py, which is where to look before changing
# what gets written.
SETTINGS="$TARGET_DIR/.claude/settings.json"
REHYDRATE_CMD="\"\$CLAUDE_PROJECT_DIR\"/scripts/wf-exec.sh wf-rehydrate.sh --hook"
if command -v python3 >/dev/null 2>&1; then
    SETTINGS_RESULT=$(SETTINGS_PATH="$SETTINGS" REHYDRATE_CMD="$REHYDRATE_CMD" \
        python3 "$SCRIPT_DIR/templates/hooks/settings-merge.py")
    case "$SETTINGS_RESULT" in
        created)      echo -e "${GREEN}  Created .claude/settings.json with the rehydration hooks${NC}" ;;
        updated)      echo -e "${GREEN}  Updated .claude/settings.json rehydration hooks${NC}" ;;
        unchanged)    echo -e "${YELLOW}  .claude/settings.json hooks already up to date — skipping${NC}" ;;
        unparseable:*)
            echo -e "${YELLOW}  .claude/settings.json is not valid JSON (${SETTINGS_RESULT#unparseable:})${NC}"
            echo -e "${YELLOW}  Left untouched. Fix it and re-run, or add the hooks by hand:${NC}"
            echo "    SessionStart  matcher compact|clear|resume  → $REHYDRATE_CMD session-start 2>/dev/null || true"
            echo "    PostCompact   matcher manual|auto           → $REHYDRATE_CMD post-compact 2>/dev/null || true" ;;
        *)            echo -e "${YELLOW}  .claude/settings.json: unexpected result '$SETTINGS_RESULT'${NC}" ;;
    esac
else
    echo -e "${YELLOW}  python3 not found — skipping .claude/settings.json hooks${NC}"
    echo -e "${YELLOW}  Add them by hand (see docs/rehydration.md):${NC}"
    echo "    SessionStart  matcher compact|clear|resume  → $REHYDRATE_CMD session-start 2>/dev/null || true"
    echo "    PostCompact   matcher manual|auto           → $REHYDRATE_CMD post-compact 2>/dev/null || true"
fi

# .claude/settings.json stays TRACKED, deliberately.
#
# It is not generated harness — the merge above touches two keys and leaves the
# project's own permissions and hooks alone — and it must be tracked for a
# reason specific to this workflow: git materialises tracked files into a new
# worktree, and an untracked settings.json means every feature worktree runs
# WITHOUT the rehydration hooks. That is exactly the session most likely to
# compact mid-implementation.
if [ -f "$SETTINGS" ] && ! git -C "$TARGET_DIR" ls-files --error-unmatch ".claude/settings.json" >/dev/null 2>&1; then
    echo -e "${YELLOW}  .claude/settings.json is untracked — commit it, or feature worktrees${NC}"
    echo -e "${YELLOW}  will start without the rehydration hooks:${NC}"
    echo "    git add .claude/settings.json && git commit -m 'chore: workflow session hooks'"
fi

# REGISTRY.md is TRACKED (v3.2.0).
#
# It used to be gitignored as "operational state", which left the pipeline's
# single source of truth as the one artifact in plans/ that git did not hold:
# plan.md, findings.md and progress.md were all versioned while the state
# machine indexing them was not, and a lost develop worktree took the whole
# pipeline's state with it, reconstructable only by hand from progress logs and
# branch names. It also made the documented row-based auto-merge rationale
# describe a mechanism that could not occur.
#
# Feature branches still never see it: wf-worktree-sparse.sh excludes plans/**
# from every feature worktree, so registry churn cannot reach a feature branch
# or arrive as a conflict when one merges back.
GITIGNORE="$TARGET_DIR/.gitignore"
if grep -qF "plans/REGISTRY.md" "$GITIGNORE" 2>/dev/null; then
    grep -vF "plans/REGISTRY.md" "$GITIGNORE" > "$GITIGNORE.tmp" && mv "$GITIGNORE.tmp" "$GITIGNORE"
    echo -e "${GREEN}  Removed plans/REGISTRY.md from .gitignore — it is tracked now${NC}"
    if [ -d "$TARGET_DIR/.git" ] || [ -f "$TARGET_DIR/.git" ]; then
        if ! git -C "$TARGET_DIR" ls-files --error-unmatch plans/REGISTRY.md >/dev/null 2>&1; then
            echo -e "${YELLOW}  plans/REGISTRY.md has never been committed. Add it:${NC}"
            echo "    git add .gitignore plans/REGISTRY.md && git commit -m 'chore: track the plan registry'"
        fi
    fi
fi

# Install workflow scripts — versioned layout (v2.0+).
# Each scripts/v*/ in the library is a complete, frozen snapshot. The
# unversioned dispatcher (scripts/wf-exec.sh) routes plans to the right
# snapshot via scripts/version-map.txt.
echo "Installing scripts..."
mkdir -p "$TARGET_DIR/scripts"

# Template each versioned snapshot.
for version_dir in "$SCRIPT_DIR/scripts"/v*/; do
    [ -d "$version_dir" ] || continue
    folder_name=$(basename "$version_dir")
    DEST_VDIR="$TARGET_DIR/scripts/$folder_name"
    mkdir -p "$DEST_VDIR"
    for script in "$version_dir"/wf-*.sh; do
        [ -f "$script" ] || continue
        # ${script##*/} rather than basename, and one chmod for the folder
        # rather than one per file: this loop runs ~80 times per client and
        # deploy-all.sh runs it for every client.
        DEST="$DEST_VDIR/${script##*/}"
        sed -e "s|{{project_slug}}|$PROJECT_SLUG|g" \
            -e "s|{{production_logs_url}}|$PRODUCTION_LOGS_URL|g" \
            -e "s|{{production_url}}|$PRODUCTION_URL|g" \
            "$script" > "$DEST"
    done
    chmod +x "$DEST_VDIR"/*.sh 2>/dev/null || true

    # Prune scripts this version no longer ships.
    #
    # scripts/v*/ is generated — everything in it was written by this loop — so
    # a wf-*.sh the source folder does not have is residue from an older
    # harness, and deploy had no way to remove one. wf-infra-sync.sh was
    # deleted from the library in v5.0.0 (its whole job was committing
    # develop's own bytes onto a feature branch, the WFI-021 shape) and four
    # clients were still carrying the August copy at v6.7.0. A stale script is
    # not inert: it is on PATH-adjacent disk, it looks current, and the one
    # thing anybody deletes a script for is that running it is a bad idea.
    for existing in "$DEST_VDIR"/wf-*.sh; do
        [ -f "$existing" ] || continue
        base="${existing##*/}"
        [ -f "$version_dir/$base" ] && continue
        rm -f "$existing"
        echo -e "${YELLOW}  Removed stale scripts/$folder_name/$base — no longer shipped${NC}"
    done
    echo -e "${GREEN}  Installed scripts/$folder_name/ ($(ls "$DEST_VDIR" | wc -l | tr -d ' ') scripts)${NC}"
done

# Dispatcher + pruning tool + version map — unversioned, copied verbatim.
for f in wf-exec.sh wf-prune-versions.sh; do
    cp "$SCRIPT_DIR/scripts/$f" "$TARGET_DIR/scripts/$f"
    chmod +x "$TARGET_DIR/scripts/$f"
    echo -e "${GREEN}  Installed scripts/$f${NC}"
done
cp "$SCRIPT_DIR/scripts/version-map.txt" "$TARGET_DIR/scripts/version-map.txt"
echo -e "${GREEN}  Installed scripts/version-map.txt${NC}"

# Gitignore workflow runtime files
GITIGNORE="$TARGET_DIR/.gitignore"
for pattern in ".wf-claim"; do
    if ! grep -qF "$pattern" "$GITIGNORE" 2>/dev/null; then
        echo "$pattern" >> "$GITIGNORE"
    fi
done

# Stamp workflow version into the target project
WORKFLOW_VERSION=$(cat "$SCRIPT_DIR/VERSION" 2>/dev/null | tr -d '[:space:]' || echo "unknown")
echo "$WORKFLOW_VERSION" > "$TARGET_DIR/.claude/workflow-version"
echo -e "${GREEN}  Stamped workflow version $WORKFLOW_VERSION → .claude/workflow-version${NC}"

# Record where this harness came from, so a client that loses it can ask the
# library for a fresh one instead of digging a stale one out of its own history.
#
# client-a's WFI-119: the reflog recovery found the newest ref that still
# TRACKED the harness — necessarily a ref from before the v5.0.0 untrack commit,
# i.e. a v3.3.0-era harness — and installed it into a project stamped 6.2.1, with
# no version check and a success message either way. Three major versions of
# stale wf-* scripts, silently. Re-running the installer is the correct recovery
# whenever the library is reachable; this file is what makes it reachable.
#
# Untracked, like the rest of the generated harness: it is a local fact about
# this machine, not something to carry to another clone.
echo "$SCRIPT_DIR" > "$TARGET_DIR/.claude/workflow-source"

# WORKFLOW.md at the project root — the entry-point contract for anyone (or
# anything) that lands in this repo without prior context: how work enters the
# pipeline, which hooks fire automatically, and the wf-orchestrate.sh exit codes
# an external process needs in order to drive a plan.
# Regenerated on every install so it can't drift from the installed version.
sed -e "s|{{project_slug}}|$PROJECT_SLUG|g" \
    -e "s|{{workflow_version}}|$WORKFLOW_VERSION|g" \
    "$SCRIPT_DIR/templates/WORKFLOW.md" > "$TARGET_DIR/WORKFLOW.md"
echo -e "${GREEN}  Installed WORKFLOW.md (project-root entry point)${NC}"

# Seed WORKFLOW-ISSUES.md so the reporting channel is discoverable before the
# first problem, not after. Created via wf-issue.sh itself (--count is a no-op
# read that writes the header when missing) so the format has exactly one owner
# and can't drift between the script and the installer.
if [ ! -f "$TARGET_DIR/WORKFLOW-ISSUES.md" ]; then
    ( cd "$TARGET_DIR" && ./scripts/wf-exec.sh wf-issue.sh --count >/dev/null 2>&1 ) || true
    [ -f "$TARGET_DIR/WORKFLOW-ISSUES.md" ] \
      && echo -e "${GREEN}  Seeded WORKFLOW-ISSUES.md (harness problems get reported here)${NC}"
fi

# ── Propagate to feature worktrees ───────────────────────────────────────────
# Resolve a worktree's plan WF stamp → script_folder using the same algorithm
# as wf-exec.sh. Only that folder (plus the unversioned dispatcher + map) gets
# copied into the worktree — so an in-flight plan keeps running the scripts it
# was built against, even after we publish newer generations.
resolve_script_folder() {
    local wf="$1"
    local map="$TARGET_ABS/scripts/version-map.txt"
    [ -z "$wf" ] && wf="0.00"
    [ -f "$map" ] || { echo ""; return; }
    local folder=""
    while IFS= read -r line; do
        line="${line%%#*}"
        [ -z "${line// }" ] && continue
        local min_ver f
        min_ver=$(echo "$line" | awk '{print $1}')
        f=$(echo "$line" | awk '{print $2}')
        [ -z "$min_ver" ] || [ -z "$f" ] && continue
        if [ "$(printf '%s\n%s\n' "$min_ver" "$wf" | sort -V | head -1)" = "$min_ver" ]; then
            folder="$f"
        fi
    done < "$map"
    echo "$folder"
}

if git -C "$TARGET_DIR" rev-parse --git-dir &>/dev/null; then
    echo "Updating feature worktrees..."
    TARGET_ABS="$(cd "$TARGET_DIR" && pwd)"
    WT_COUNT=0

    wt_path="" wt_branch=""
    while IFS= read -r line; do
        if [[ "$line" == worktree\ * ]]; then
            wt_path="${line#worktree }"
            wt_branch=""
        elif [[ "$line" == branch\ * ]]; then
            wt_branch="${line#branch }"
        elif [[ -z "$line" ]]; then
            # End of block — process if it's a feature worktree (not the main one)
            if [[ -n "$wt_path" && "$wt_path" != "$TARGET_ABS" && "$wt_branch" == *feature/* ]]; then
                # Resolve this worktree's plan WF → script folder.
                # Branch format: refs/heads/feature/PLN-NNN[-slug]
                wt_plan_id=$(echo "$wt_branch" | grep -oE 'PLN-[0-9]+' | head -1 || true)
                wt_wf=""
                if [ -n "$wt_plan_id" ] && [ -f "$TARGET_ABS/plans/REGISTRY.md" ]; then
                    row=$(grep "^| ${wt_plan_id} " "$TARGET_ABS/plans/REGISTRY.md" | head -1 || true)
                    # WF column is field $8 in 7-column registry (ID|Slug|State|Priority|Branch|Updated|WF)
                    [ -n "$row" ] && wt_wf=$(echo "$row" | awk -F'|' '{print $8}' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
                fi
                wt_folder=$(resolve_script_folder "$wt_wf")

                # Re-run sparse configuration first: it repairs a worktree set
                # up by an older pattern list, and clears the deploy copies
                # this step used to leave behind.
                if [ -n "$wt_folder" ] && [ -x "$TARGET_ABS/scripts/$wt_folder/wf-worktree-sparse.sh" ]; then
                    "$TARGET_ABS/scripts/$wt_folder/wf-worktree-sparse.sh" "$wt_path" >/dev/null 2>&1 || true
                fi

                # Put the three must-exist paths on the worktree's disk.
                #
                # They are gitignored now, so this is the ONLY way they arrive
                # — git no longer materialises them, and nothing reconciles
                # them afterwards because an ignored file cannot be dirty,
                # cannot conflict, and cannot abort a merge. Everything else
                # workflow-owned resolves from the MAIN worktree.
                if [ -x "$TARGET_ABS/scripts/$wt_folder/wf-worktree-harness.sh" ]; then
                    "$TARGET_ABS/scripts/$wt_folder/wf-worktree-harness.sh" "$wt_path" >/dev/null 2>&1 || true
                fi

                echo -e "  ${GREEN}Updated $(basename "$wt_path") (skills + wf-exec.sh; scripts/${wt_folder:-none} resolved from develop, WF=${wt_wf:-0.00})${NC}"
                ((WT_COUNT++)) || true
            fi
            wt_path="" wt_branch=""
        fi
    done < <(git -C "$TARGET_DIR" worktree list --porcelain; echo "")

    [ "$WT_COUNT" -gt 0 ] && echo -e "${GREEN}  $WT_COUNT worktree(s) updated${NC}" || echo -e "  ${YELLOW}No feature worktrees found${NC}"
    echo ""
fi

# Always overwrite .claude/workflow.md (the referenced file — keeps it current on every deploy)
WORKFLOW_MD="$TARGET_DIR/.claude/workflow.md"
sed -e "s|{{build_command}}|$BUILD_CMD|g" \
    -e "s|{{test_command}}|$TEST_CMD|g" \
    -e "s|{{source_dirs}}|$SOURCE_DIRS|g" \
    "$SCRIPT_DIR/claude-md/workflow-snippet.md" > "$WORKFLOW_MD"
echo -e "${GREEN}  Installed .claude/workflow.md${NC}"

# Add @import to CLAUDE.md once — never needs updating after that
CLAUDE_MD="$TARGET_DIR/CLAUDE.md"
IMPORT_LINE="@.claude/workflow.md"
if [ -f "$CLAUDE_MD" ]; then
    if grep -qF "$IMPORT_LINE" "$CLAUDE_MD"; then
        echo -e "${YELLOW}  CLAUDE.md already imports workflow — skipping${NC}"
    else
        echo "" >> "$CLAUDE_MD"
        echo "$IMPORT_LINE" >> "$CLAUDE_MD"
        echo -e "${GREEN}  Added workflow import to CLAUDE.md${NC}"
    fi
else
    echo "$IMPORT_LINE" > "$CLAUDE_MD"
    echo -e "${GREEN}  Created CLAUDE.md with workflow import${NC}"
fi

# ── Land the deploy's own tracked changes ────────────────────────────────
#
# Almost everything this installer writes is gitignored in the client as of
# v5.0.0 — scripts/v*/, .claude/skills/wf-*/, the hooks. A handful of paths are
# deliberately NOT: the project's config, the entry contract, the version
# stamp, the plan template. Those are tracked, so a deploy left the client's
# develop dirty and walked away.
#
# That is not cosmetic. The next worker into that repo reads an uncommitted
# `.claude/workflow-version` and a modified `claude-workflow.yml` as somebody
# else's work in progress and has to decide what to do about it — client-a's
# WFI-131 filed exactly that, mid-plan, and worked around it by leaving the
# changes alone. Meanwhile the files are on the shared develop index, where the
# next `wf-commit.sh` from any live worker would have carried them under that
# plan's message.
#
# So the deploy owns its own changes: pathspec-scoped, its own commit, nothing
# else swept in. `git commit -- <paths>` commits those paths from the working
# tree and leaves the rest of the index alone, which is what makes it safe to
# run while other workers have things staged.
if $INSTALL_COMMIT && git -C "$TARGET_DIR" rev-parse --verify --quiet HEAD >/dev/null 2>&1; then
    DEPLOY_PATHS=()
    for p in claude-workflow.yml WORKFLOW.md .claude/workflow-version plans/TEMPLATE.md CLAUDE.md .gitignore; do
        git -C "$TARGET_DIR" ls-files --error-unmatch -- "$p" >/dev/null 2>&1 || continue
        git -C "$TARGET_DIR" diff --quiet -- "$p" 2>/dev/null || DEPLOY_PATHS+=("$p")
    done

    if [ ${#DEPLOY_PATHS[@]} -gt 0 ]; then
        DEPLOY_BRANCH=$(git -C "$TARGET_DIR" branch --show-current 2>/dev/null || true)
        case "$DEPLOY_BRANCH" in
            develop|main|master|release)
                if git -C "$TARGET_DIR" commit --quiet \
                     -m "chore: sync workflow harness to v$WORKFLOW_VERSION" \
                     -- "${DEPLOY_PATHS[@]}" 2>/dev/null; then
                    echo -e "${GREEN}  Committed ${#DEPLOY_PATHS[@]} tracked path(s) on $DEPLOY_BRANCH — tree left clean${NC}"
                else
                    echo -e "${YELLOW}  Could not commit ${DEPLOY_PATHS[*]} — commit them before another worker does${NC}"
                fi
                ;;
            *)
                # A feature branch or a human's own session: the deploy's
                # changes belong on develop, not stacked onto whatever this is.
                echo -e "${YELLOW}  Left ${DEPLOY_PATHS[*]} uncommitted — checkout is on '${DEPLOY_BRANCH:-detached HEAD}',${NC}"
                echo -e "${YELLOW}    not a branch a deploy should commit to. Land them from develop.${NC}"
                ;;
        esac
    fi
fi

echo ""
echo -e "${GREEN}Installation complete!${NC}"
echo ""
echo "Available skills:"
echo "  /wf-init        — one-time setup (logging, terminal role)"
echo "  /wf-next        — run your role's skill automatically"
echo "  /wf-help        — display workflow strategy & architecture"
echo "  /wf-status      — see pipeline status and next action"
echo "  /wf-brainstorm  — capture and explore ideas"
echo "  /wf-spec        — create implementation plan from a brief"
echo "  /wf-review      — architecture and security review"
echo "  /wf-implement   — build from a plan"
echo "  /wf-verify      — check implementation against plan"
echo "  /wf-debug       — interactive debug session"
echo "  /wf-bug         — file a bug report"
echo "  /wf-info        — full history and status for any plan, bug, or brief"
echo "  /wf-consistency — check a plan against its dependency closure"
echo "  /wf-rollback    — revert a completed plan"
echo ""
echo "Orchestrated mode (run the pipeline from one terminal):"
echo "  /wf-board       — live view: workers, gates, pipeline, events"
echo "  /wf-attend      — drain the queue of decisions needing a human"
echo "  /wf-orchestrate — drive one item end to end, or manage the daemon"
echo ""
echo "  The orchestrator ships DISABLED. Preview it before enabling:"
echo "    scripts/wf-exec.sh wf-orchestrate.sh --sweep --dry-run"
echo "  Then set orchestrator.enabled: true in claude-workflow.yml."
echo ""
echo "Start with: /wf-init (setup) → /wf-next (run your role)"
echo "See WORKFLOW.md in the project root for the full entry-point contract."
