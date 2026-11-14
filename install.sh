#!/bin/bash
set -euo pipefail

# Pre-14.0.0 environment names: each WF_* still seeds its LV_* counterpart
# unless that is set already, so shell profiles and daemons started before the
# rename keep working.
for _wf in $(compgen -e | grep '^WF_' || true); do
  _lv="LV_${_wf#WF_}"; [ -n "${!_lv+x}" ] || export "$_lv=${!_wf}"
done; unset _wf _lv

# Levain installer
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
[ "${LV_INSTALL_NO_COMMIT:-0}" = "1" ] && INSTALL_COMMIT=false

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# ── Atomic writes ────────────────────────────────────────────────────────────
#
# NO PATH A RUNNING PROCESS RESOLVES IS EVER WRITTEN TWICE.
#
# This installer used to render every generated file with a plain `>`, which
# truncates the destination and then fills it. For the length of that loop the
# client's script folder is a mixture of two harnesses and each file in it is
# briefly zero bytes. An orchestrator daemon sweeps out of that same folder
# every 60s; a sweep landing in the window reads a half-replaced harness, says
# nothing, and misbehaves an hour later (coordinator WFI-003). Every guard in
# deploy-all.sh existed to keep callers out of that window.
#
# A write to `$dest.wftmp.$$` followed by `mv` over `$dest` is a rename(2):
# atomic, so a reader sees either the whole old file or the whole new one and
# never a third thing. Same directory, so it never crosses a filesystem.
#
# This works because $dest is a REGULAR FILE. It would not work for a symlink —
# BSD `mv` dereferences a destination that points at a directory and moves the
# source *inside* it, silently. That is why scripts/current is a file and not a
# symlink; see docs/atomic-deploy.md.
atomic_write() {
    # atomic_write <dest>   — content on stdin
    local dest="$1" tmp="$1.wftmp.$$"
    cat > "$tmp" || { rm -f "$tmp"; return 1; }
    mv -f "$tmp" "$dest"
}

# ── The docs a skill links, on the client's disk ─────────────────────────────
#
# Skills cite `docs/*.md` as the authority for the contracts they follow — guard
# ordering for an exit path, worktrees for what a feature checkout may hold —
# and link them relatively from `.claude/skills/lv-*/SKILL.md`, which resolves
# to `.claude/docs/`. Nothing ever put them there. Every one of those links has
# been dead in every client since the day it was written, and a worker that
# follows one to settle a question finds no file and no directory: client-b
# WFI-022 reached for guard-ordering.md mid-replan, found neither, and had to
# reconstruct the rule from the fragments the skills restate inline — which is
# exactly the half that omits the race-safety argument.
#
# The set is DERIVED from what the installed skills actually link, never listed
# here. A list is a second place to update, and forgetting to is precisely the
# dead link this exists to prevent.
install_referenced_docs() {
    # install_referenced_docs <skills-root> <docs-dest>
    local skills_root="$1" docs_dest="$2" wanted name existing count=0
    [ -d "$skills_root" ] || return 0
    wanted=$(grep -rhoE 'docs/[a-z0-9-]+\.md' "$skills_root" 2>/dev/null \
             | sed 's|^docs/||' | sort -u)
    mkdir -p "$docs_dest"
    for name in $wanted; do
        [ -f "$SCRIPT_DIR/docs/$name" ] || continue
        render_ids < "$SCRIPT_DIR/docs/$name" | atomic_write "$docs_dest/$name"
        count=$((count + 1))
    done
    # Subtractive, like the rest of the generated harness: a doc the skills
    # stopped citing, or one renamed upstream, is a stale copy that still reads
    # as current. This directory holds generated content and nothing else.
    for existing in "$docs_dest"/*.md; do
        [ -f "$existing" ] || continue
        if ! printf '%s\n' "$wanted" | grep -qxF "$(basename "$existing")"; then
            rm -f "$existing"
        fi
    done
    if [ "$count" -gt 0 ]; then
        echo -e "${GREEN}  Installed $count referenced doc(s) → ${docs_dest#"$TARGET_DIR"/}${NC}"
    fi
    return 0
}

atomic_install() {
    # atomic_install <src> <dest> [mode]
    local src="$1" dest="$2" mode="${3:-}" tmp="$2.wftmp.$$"
    cp "$src" "$tmp" || { rm -f "$tmp"; return 1; }
    [ -n "$mode" ] && chmod "$mode" "$tmp"
    mv -f "$tmp" "$dest"
}

# ── Build identity ───────────────────────────────────────────────────────────
#
# Every deploy produces a directory name that has never existed, so the build
# can be published by a single rename with no destination to displace. Without
# the timestamp, re-deploying the same workflow version — the common case while
# developing the library — would have to overwrite a live folder, which is the
# exact thing this design removes.
WORKFLOW_VERSION=$(cat "$SCRIPT_DIR/VERSION" 2>/dev/null | tr -d '[:space:]' || echo "unknown")
BUILD_ID="$WORKFLOW_VERSION-$(date -u +%Y%m%d%H%M%S)"

GEN_ROOT="$TARGET_DIR/scripts/gen"
GEN_STAGE="$GEN_ROOT/.building.$$"
CURRENT_FILE="$TARGET_DIR/scripts/current"
PREV_BUILD=""

gen_stage_begin() {
    # A staging directory nothing resolves. Torn down on any exit before the
    # publish, so a failed install leaves no partial build behind for the
    # retention pass to have an opinion about.
    rm -rf "$GEN_STAGE"
    mkdir -p "$GEN_STAGE"
    trap 'rm -rf "$GEN_STAGE"' EXIT
}

gen_publish() {
    # Publish the staged build, then flip the pointer. THE FLIP DELIBERATELY
    # PRECEDES the replacement of lv-exec.sh and version-map.txt in both
    # install paths — see docs/atomic-deploy.md, "Flip order". Reversing it
    # pairs a new dispatcher with a pointer that still names the outgoing
    # build, which is the one combination that does not resolve.
    [ -e "$GEN_ROOT/$BUILD_ID" ] && rm -rf "$GEN_ROOT/$BUILD_ID"
    mv "$GEN_STAGE" "$GEN_ROOT/$BUILD_ID"
    trap - EXIT

    [ -f "$CURRENT_FILE" ] && PREV_BUILD=$(tr -d '[:space:]' < "$CURRENT_FILE")
    printf '%s\n' "$BUILD_ID" | atomic_write "$CURRENT_FILE"
    echo -e "${GREEN}  Published scripts/gen/$BUILD_ID and flipped scripts/current${NC}"
}

build_in_use() {
    # Is any live process running out of this build? Its path appears verbatim
    # in the command line of anything launched from it — the daemon
    # (`bash .../gen/<build>/v2.00/lv-orchestrate.sh --daemon`) and every
    # worker wrapper lv-spawn.sh detaches, which carries the build's
    # lv-event.sh for the whole life of the run.
    local base="$1"
    command -v pgrep >/dev/null 2>&1 || return 1
    pgrep -f "/gen/$base/" >/dev/null 2>&1
}

# ── The 14.0.0 prefix rename (wf- → lv-) ─────────────────────────────────
#
# Every shipped skill and top-level script was renamed. The install loops write
# only lv-* names, so without this the old wf-* copies would stay invocable
# beside their successors — two /spec skills, one of them frozen at 13.x. Only
# the old names of skills this library ships are removed: a project's own wf-*
# skill, if it has one, is its business. scripts/wf-exec.sh is not removed; it
# is reinstalled as a shim that hands off to lv-exec.sh.
prune_legacy_prefix() {
    local d n
    for d in "$SCRIPT_DIR/skills"/lv-*/; do
        n=$(basename "$d"); n="${n#lv-}"
        [ "$n" = tray ] && n=board
        if [ -d "$TARGET_DIR/.claude/skills/wf-$n" ]; then
            rm -rf "$TARGET_DIR/.claude/skills/wf-$n"
            echo -e "${YELLOW}  Removed /wf-$n — renamed /$(basename "$d") in 14.0.0${NC}"
        fi
    done
    rm -f "$TARGET_DIR/scripts/wf-prune-versions.sh"
}

gen_retire() {
    # Keep the new build, the one it replaced, and any build something is
    # still running out of. Nothing older.
    #
    # "Current and previous" alone was the rule, on the assumption that the
    # only thing holding a build open is a subprocess that lasts seconds. That
    # is false twice over: an implement worker runs for hours out of the build
    # it was launched from, and a daemon runs out of one indefinitely. Two
    # deploys inside a minute retired a build under both — client-a WFI-256
    # (a finished worker lost its exit event) and WFI-257 (the daemon kept
    # sweeping from a deleted tree, every spawn rc=127, for 71 minutes while
    # reporting itself healthy). Both now also defend themselves — lv-spawn.sh
    # falls back to the dispatcher, the daemon re-execs onto the live build —
    # but a deploy that deletes a tree out from under a running process is the
    # cause, and this is where it is prevented.
    local d base
    for d in "$GEN_ROOT"/*/; do
        [ -d "$d" ] || continue
        base=$(basename "$d")
        [ "$base" = "$BUILD_ID" ] && continue
        [ -n "$PREV_BUILD" ] && [ "$base" = "$PREV_BUILD" ] && continue
        case "$base" in .building.*) ;; *)
            if build_in_use "$base"; then
                echo -e "${YELLOW}  Kept scripts/gen/$base — a live process is running out of it${NC}"
                continue
            fi
            echo -e "${YELLOW}  Retired scripts/gen/$base${NC}" ;;
        esac
        rm -rf "$d"
    done

    # Legacy pre-gen folders. NOT removed by the deploy that introduces gen/ —
    # they are what an old dispatcher still mid-run resolves through, and a
    # process that started before the flip may yet spawn a sibling out of one.
    # A non-empty PREV_BUILD means this client was already gen-era before this
    # install began, so by now nothing can be resolving them.
    if [ -n "$PREV_BUILD" ]; then
        for d in "$TARGET_DIR/scripts"/v*/; do
            [ -d "$d" ] || continue
            rm -rf "$d"
            echo -e "${YELLOW}  Removed legacy scripts/$(basename "$d")/ — superseded by scripts/gen/${NC}"
        done
    fi
}

echo "Levain installer"
echo "========================"
echo ""

# Check for config
CONFIG_FILE="$TARGET_DIR/levain.yml"
OLD_CONFIG="$TARGET_DIR/claude-workflow.yml"
# 14.7.0 renamed the config from claude-workflow.yml. Move it once, as a git
# rename where it is tracked, so history follows it and the deploy's own commit
# below carries both sides. Every reader still falls back to the old name, so a
# feature branch cut before the rename keeps working until it merges.
CONFIG_RENAMED=false
if [ ! -f "$CONFIG_FILE" ] && [ -f "$OLD_CONFIG" ]; then
    if git -C "$TARGET_DIR" ls-files --error-unmatch -- claude-workflow.yml >/dev/null 2>&1; then
        git -C "$TARGET_DIR" mv claude-workflow.yml levain.yml
    else
        mv "$OLD_CONFIG" "$CONFIG_FILE"
    fi
    CONFIG_RENAMED=true
    echo -e "${GREEN}Renamed claude-workflow.yml → levain.yml${NC}"
elif [ -f "$CONFIG_FILE" ] && [ -f "$OLD_CONFIG" ]; then
    echo -e "${YELLOW}Both levain.yml and claude-workflow.yml exist — using levain.yml. Remove the old one.${NC}"
fi
if [ ! -f "$CONFIG_FILE" ]; then
    echo -e "${YELLOW}No levain.yml found in $TARGET_DIR${NC}"
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

# sed_lit VALUE — VALUE made literal for the replacement side of `s|...|...|`.
#
# Every config value is rendered through `sed -e "s|{{key}}|$(sed_lit "$VALUE")|g"`, and in
# a replacement `&` means "the matched text", `\` escapes, and `|` ends the
# expression. So `node build.ts && node lineage.ts` rendered as
# `node build.ts {{local_deploy_command}}{{local_deploy_command}} node ...` —
# a shell command that could never run, installed without a word
# (LVI-034). Any `&&` in a build, test or start command did the same.
sed_lit() {
    printf '%s' "$1" | sed -e 's/[\\&|]/\\&/g'
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
ROLE=$(get_config "role")
ROLE="${ROLE:-client}"
# The overseer rung's skills (LVI-014): a coordinator installs these and no
# pipeline skill; a client installs every other skill and none of these.
COORD_SKILLS="lv-dep-notify lv-rack lv-sweep lv-vision"
COORD_ONLY_SKILLS="lv-rack lv-sweep lv-vision"

case "$ROLE" in
    client|coordinator) ;;
    *)  RED='\033[0;31m'
        echo -e "${RED}ERROR: role must be 'client' or 'coordinator' (got '$ROLE').${NC}"
        echo "See docs/coordinator.md."
        exit 1 ;;
esac

# The artifact ID prefix map (scripts/v2.00/lv-ids.sh). Checked before anything
# is written: a malformed prefix, or one claimed by two kinds, would have the
# pipeline issue IDs it cannot read back.
if ! IDS_ERR=$( cd "$TARGET_DIR" && bash "$SCRIPT_DIR/scripts/v2.00/lv-ids.sh" check 2>&1 >/dev/null ); then
    RED='\033[0;31m'
    echo -e "${RED}ERROR: the ids: map in $CONFIG_FILE is not usable:${NC}"
    printf '%s\n' "$IDS_ERR" | sed 's/^/    /'
    exit 1
fi
TARGET_PLAN_RE=$( cd "$TARGET_DIR" && bash "$SCRIPT_DIR/scripts/v2.00/lv-ids.sh" match plan )

# render_ids — a filter: the default ID prefixes in prose become the ones this
# project issues, so a skill that says "PLN-NNN" says "LOAF-NNN" where the map
# renames plans. A straight copy under the default map.
render_ids() {
    ( cd "$TARGET_DIR" && bash "$SCRIPT_DIR/scripts/v2.00/lv-ids.sh" render )
}

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

# ── Coordinator installs ─────────────────────────────────────────────────────
#
# A coordinator (role: coordinator) oversees several projects that DO run the
# pipeline, and files work into theirs. It runs none of its own: no plans/, no
# REGISTRY, no bugs/, no worktrees, no orchestrator, no pipeline skills, and
# none of the git or session hooks that drive them. One person overseeing several
# projects is the case this exists for.
#
# It still needs the harness on disk, for two reasons that pull in the same
# direction. First, filing has to go through the TARGET's own lv-bug-new.sh —
# that is what makes the ID come from the target's own counter and the file land
# where the target's own /lv-spec already looks (docs/cross-project-reports.md).
# Reaching that requires lv-dep-notify.sh here. Second, a coordinator that has
# to reason about work in five pipelines needs an accurate description of how
# those pipelines behave, and the only description that cannot drift is one the
# library regenerates on every deploy. Hence WORKFLOW-coordinator.md.
#
# This is a self-contained early exit rather than conditionals threaded through
# the client install below. The two paths share almost nothing, and interleaving
# them would put a `[ "$ROLE" = client ]` guard on forty blocks whose failure
# mode is silent — writing a pipeline artifact into a repo with no pipeline.
if [ "$ROLE" = "coordinator" ]; then
    echo -e "${GREEN}Role: coordinator${NC} — filing capability only, no pipeline"
    echo ""

    mkdir -p "$TARGET_DIR/.claude" "$TARGET_DIR/scripts"

    # The slice a coordinator gets. Everything here is either a filing path or
    # something a filing path sources. Anything absent is absent DELIBERATELY:
    # a pipeline script sitting on a coordinator's disk looks current, is on
    # PATH-adjacent disk, and the only reason to withhold it is that running it
    # here is a bad idea — the same argument install.sh already makes for
    # pruning stale scripts out of a client.
    COORD_SCRIPTS="lv-orch-lib.sh lv-lock.sh lv-ids.sh lv-dep-notify.sh lv-dep-bug.sh lv-issue.sh lv-hook.sh lv-rack.sh lv-direct.sh lv-bug-group.sh lv-library-sweep.sh lv-guard-baseline.sh"

    echo "Installing scripts..."
    # Built into a staging directory nothing resolves, then published and
    # flipped in one move. The slice is subtractive by construction now: a
    # build starts empty, so a coordinator can no longer inherit a stale
    # pipeline script from a former client install by the deploy simply
    # failing to notice it.
    gen_stage_begin
    COORD_FOLDERS=""
    for version_dir in "$SCRIPT_DIR/scripts"/v*/; do
        [ -d "$version_dir" ] || continue
        # Only a generation that actually ships the filing path. An older
        # folder without it would install as an empty directory that lv-exec.sh
        # could still resolve to, and then fail with "missing or not
        # executable" on every call.
        [ -f "$version_dir/lv-dep-notify.sh" ] || continue
        folder_name=$(basename "$version_dir")
        COORD_FOLDERS="$COORD_FOLDERS $folder_name"
        DEST_VDIR="$GEN_STAGE/$folder_name"
        mkdir -p "$DEST_VDIR"
        for name in $COORD_SCRIPTS; do
            [ -f "$version_dir/$name" ] || continue
            sed -e "s|{{project_slug}}|$(sed_lit "$PROJECT_SLUG")|g" \
                -e "s|{{production_logs_url}}|$(sed_lit "$PRODUCTION_LOGS_URL")|g" \
                -e "s|{{production_url}}|$(sed_lit "$PRODUCTION_URL")|g" \
                "$version_dir/$name" > "$DEST_VDIR/$name"
        done
        [ -d "$version_dir/hooks.default" ] && cp -R "$version_dir/hooks.default" "$DEST_VDIR/"
        chmod +x "$DEST_VDIR"/*.sh 2>/dev/null || true
        echo -e "${GREEN}  Staged $folder_name/ ($(ls "$DEST_VDIR" | wc -l | tr -d ' ') scripts)${NC}"
    done

    if [ -z "$COORD_FOLDERS" ]; then
        RED='\033[0;31m'
        echo -e "${RED}ERROR: no script generation in the library ships lv-dep-notify.sh${NC}"
        exit 1
    fi

    gen_publish

    for f in lv-exec.sh lv-prune-versions.sh wf-exec.sh; do
        atomic_install "$SCRIPT_DIR/scripts/$f" "$TARGET_DIR/scripts/$f" +x
    done
    atomic_install "$SCRIPT_DIR/scripts/version-map.txt" "$TARGET_DIR/scripts/version-map.txt"
    echo -e "${GREEN}  Installed scripts/lv-exec.sh + version-map.txt${NC}"

    gen_retire

    # Legacy pre-gen folders that gen_retire deliberately leaves standing on the
    # first gen-era deploy. A coordinator cannot be left carrying a full
    # pipeline harness for a whole deploy cycle just because the fallback path
    # wants those folders intact — "a pipeline script here looks current, and
    # the only reason to withhold it is that running it is a bad idea" is the
    # rule the whole coordinator slice is built on. So the folders stay and
    # their contents are cut back to the slice.
    for existing_dir in "$TARGET_DIR/scripts"/v*/; do
        [ -d "$existing_dir" ] || continue
        for existing in "$existing_dir"lv-*.sh "$existing_dir"wf-*.sh; do
            [ -f "$existing" ] || continue
            base="${existing##*/}"
            case " $COORD_SCRIPTS " in *" $base "*) continue ;; esac
            rm -f "$existing"
            echo -e "${YELLOW}  Removed legacy $(basename "$existing_dir")/$base — not part of a coordinator install${NC}"
        done
    done

    # The overseer's skills: filing into the projects this one coordinates,
    # the cross-project board, and the vision (LVI-014).
    echo "Installing skills..."
    for name in $COORD_SKILLS; do
        COORD_SKILL_DIR="$TARGET_DIR/.claude/skills/$name"
        mkdir -p "$COORD_SKILL_DIR"
        sed -e "s|{{project_slug}}|$(sed_lit "$PROJECT_SLUG")|g" \
            "$SCRIPT_DIR/skills/$name/SKILL.md" | render_ids | atomic_write "$COORD_SKILL_DIR/SKILL.md"
        echo -e "${GREEN}  Installed /$name${NC}"
    done

    # Same rule as a client, over the coordinator's skills: only the docs they
    # actually cite, and none of the pipeline docs a former client install
    # left behind. The owner's own skills here (a vision skill) count too.
    install_referenced_docs "$TARGET_DIR/.claude/skills" "$TARGET_DIR/.claude/docs"

    prune_legacy_prefix

    # Pipeline skills from a former client install. Left in place they are
    # invocable, and every one of them starts by grepping a REGISTRY.md that
    # does not exist here.
    for stale in "$TARGET_DIR/.claude/skills"/lv-*/; do
        [ -d "$stale" ] || continue
        case " $COORD_SKILLS " in *" $(basename "$stale") "*) continue ;; esac
        rm -rf "$stale"
        echo -e "${YELLOW}  Removed /$(basename "$stale") — pipeline skill, not installed on a coordinator${NC}"
    done

    printf '%s\n' "$WORKFLOW_VERSION" | atomic_write "$TARGET_DIR/.claude/workflow-version"
    printf '%s\n' "$SCRIPT_DIR" | atomic_write "$TARGET_DIR/.claude/workflow-source"
    echo -e "${GREEN}  Stamped workflow version $WORKFLOW_VERSION → .claude/workflow-version${NC}"

    # The entry contract. A coordinator's version describes the pipelines it
    # files into and where its own authority stops — regenerated every deploy,
    # so it cannot drift from the harness the coordinated projects are running.
    sed -e "s|{{project_slug}}|$(sed_lit "$PROJECT_SLUG")|g" \
        -e "s|{{workflow_version}}|$(sed_lit "$WORKFLOW_VERSION")|g" \
        "$SCRIPT_DIR/templates/WORKFLOW-coordinator.md" | render_ids | atomic_write "$TARGET_DIR/WORKFLOW.md"
    echo -e "${GREEN}  Installed WORKFLOW.md (coordinator entry point)${NC}"

    if [ ! -f "$TARGET_DIR/WORKFLOW-ISSUES.md" ]; then
        ( cd "$TARGET_DIR" && ./scripts/lv-exec.sh lv-issue.sh --count >/dev/null 2>&1 ) || true
        [ -f "$TARGET_DIR/WORKFLOW-ISSUES.md" ] \
          && echo -e "${GREEN}  Seeded WORKFLOW-ISSUES.md (harness problems get reported here)${NC}"
    fi

    # Same rule as a client: what the harness generates, git does not track. The
    # list is shorter because the install is — but not as short as it was:
    # `.claude/orchestrator/` is created at RUNTIME in a coordinator checkout
    # too (lv-issue.sh reaches it through lv-orch-lib.sh), and the rule for it
    # was only appended on the client path, which a coordinator never reaches.
    # coordinator carried `?? .claude/orchestrator/` in every git status from the day it
    # first filed an issue — permanent noise, which trains an operator to skim
    # past the untracked list where a genuinely unexpected file would appear
    # (coordinator WFI-004).
    GITIGNORE="$TARGET_DIR/.gitignore"
    COORD_IGNORED=0
    for pattern in \
        ".claude/skills/lv-*/" \
        ".claude/skills/wf-*/" \
        ".claude/docs/" \
        ".claude/workflow-source" \
        "scripts/lv-exec.sh" \
        "scripts/wf-exec.sh" \
        "scripts/version-map.txt" \
        "scripts/lv-prune-versions.sh" \
        "scripts/v*/" \
        "scripts/gen/" \
        "scripts/current" \
        ".claude/orchestrator/" ; do
        if ! grep -qxF "$pattern" "$GITIGNORE" 2>/dev/null; then
            echo "$pattern" >> "$GITIGNORE"
            COORD_IGNORED=$((COORD_IGNORED + 1))
        fi
    done
    [ "$COORD_IGNORED" -gt 0 ] && \
      echo -e "${GREEN}  Added $COORD_IGNORED generated-harness pattern(s) to .gitignore${NC}"

    # Pipeline DATA is never removed, only reported. Scripts and skills are
    # generated and the library owns them; plans/ and bugs/ are tracked work
    # that a human wrote, and a role typo must not be able to delete it.
    if [ -f "$TARGET_DIR/plans/REGISTRY.md" ] || [ -d "$TARGET_DIR/bugs" ]; then
        echo -e "${YELLOW}  This project still has plans/ or bugs/ on disk, but runs no pipeline now.${NC}"
        echo -e "${YELLOW}    Left untouched — deploy does not delete tracked work. If role: coordinator${NC}"
        echo -e "${YELLOW}    is correct, drain or archive them by hand; if it is a typo, set role: client.${NC}"
    fi

    if ! grep -q "WORKFLOW.md" "$TARGET_DIR/CLAUDE.md" 2>/dev/null; then
        echo -e "${YELLOW}  CLAUDE.md does not mention WORKFLOW.md — point at it, or a session${NC}"
        echo -e "${YELLOW}    here will never learn what it may and may not do to a coordinated project.${NC}"
    fi

    # The deploy owns its own tracked changes, same as the client path below.
    if $INSTALL_COMMIT && git -C "$TARGET_DIR" rev-parse --verify --quiet HEAD >/dev/null 2>&1; then
        COORD_PATHS=()
        for p in levain.yml WORKFLOW.md .claude/workflow-version .gitignore; do
            git -C "$TARGET_DIR" ls-files --error-unmatch -- "$p" >/dev/null 2>&1 || continue
            git -C "$TARGET_DIR" diff --quiet -- "$p" 2>/dev/null || COORD_PATHS+=("$p")
        done
        $CONFIG_RENAMED && COORD_PATHS+=(levain.yml claude-workflow.yml)
        if [ ${#COORD_PATHS[@]} -gt 0 ]; then
            if git -C "$TARGET_DIR" commit --quiet \
                 -m "chore: sync workflow harness to v$WORKFLOW_VERSION" \
                 -- "${COORD_PATHS[@]}" 2>/dev/null; then
                echo -e "${GREEN}  Committed ${#COORD_PATHS[@]} tracked path(s) — tree left clean${NC}"
            else
                echo -e "${YELLOW}  Could not commit ${COORD_PATHS[*]} — commit them by hand${NC}"
            fi
        fi
    fi

    echo ""
    echo -e "${GREEN}Coordinator installation complete!${NC}"
    echo ""
    echo "Available skills:"
    echo "  /lv-rack        — the board: every coordinated project's pipeline, and what waits on you"
    echo "  /lv-sweep       — heal the library: sweep client issues, deploy, publish"
    echo "  /lv-dep-notify  — file a request, bug or notice into a coordinated project"
    echo "  /lv-vision      — your vision skill, or the interview that writes one"
    echo ""
    echo "This project runs no pipeline of its own. See WORKFLOW.md for what it may"
    echo "and may not do to a project it coordinates."
    exit 0
fi

# Read source_dirs as comma-separated string.
#
# `|| true` because this is a PIPELINE under `set -o pipefail`: a config with no
# `source_dirs:` block makes both greps exit 1, the command substitution takes
# that status, and `set -e` kills the installer on an assignment — after the
# banner and before a single word of output. An installer whose failure mode is
# "prints nothing, exits 1" is the WFI-191 shape; an absent optional key is not
# an error.
SOURCE_DIRS=$(grep -A 10 "^source_dirs:" "$CONFIG_FILE" | grep "^  - " | sed 's/^  - //' | sed 's/"//g' | tr '\n' ', ' | sed 's/,$//') || true

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

# The test-account keys existed only in lv-docker-up.sh's source comments, so
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
# many `#### Manual` criteria the planner wrote. Absent, lv-manual-gate.sh
# falls back to pre-3.0 behavior (stop whenever anything manual remains).
if ! grep -q "^manualTestGate:" "$CONFIG_FILE" 2>/dev/null; then
    printf '\n' >> "$CONFIG_FILE"
    extract_block "# ── Manual-test gate" >> "$CONFIG_FILE"
    echo -e "${GREEN}  Added manualTestGate: block to $CONFIG_FILE${NC}"
    echo -e "${YELLOW}    Review renderingSurfaces — the defaults cover common web front ends; add this project's UI paths${NC}"
fi

# v3.0: who approves a spec. Ships as `gate` — today's behavior — so nothing
# changes for an existing client until they opt in.
if ! grep -q "^specApproval:" "$CONFIG_FILE" 2>/dev/null; then
    printf '\n' >> "$CONFIG_FILE"
    extract_block "# ── Spec approval" >> "$CONFIG_FILE"
    echo -e "${GREEN}  Added specApproval: block to $CONFIG_FILE (mode: gate — unchanged behavior)${NC}"
fi

# v6.29: the paths where THIS project talks about a plan without implementing
# it. Absent, lv-prior-work.sh uses its four built-ins alone — today's
# behavior — so nothing changes for an existing client until they list one.
if ! grep -q "^priorWork:" "$CONFIG_FILE" 2>/dev/null; then
    printf '\n' >> "$CONFIG_FILE"
    extract_block "# ── Prior work" >> "$CONFIG_FILE"
    echo -e "${GREEN}  Added priorWork: block to $CONFIG_FILE (empty — unchanged behavior)${NC}"
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
    # lv-spec was already writing 9-field rows, so header and rows disagreed
    # from the first plan onwards — lv-set-tags.sh patched it per row, which
    # hid the mismatch instead of fixing it.
    if grep -qE '^\| ID \|.*\| WF \|' "$REGISTRY_DEST" && ! grep -qE '^\| ID \|.*\| Tags \|' "$REGISTRY_DEST"; then
        echo "  Migrating REGISTRY.md → adding Tags and Deps columns"
        awk 'BEGIN{OFS=""}
             NR==FNR{if(/^\| ID \|/){hdr=NR}; if(hdr && NR==hdr+1){sep=NR}; next}
             {
               if(FNR==hdr){sub(/\|[[:space:]]*$/, "| Tags | Deps |"); print; next}
               if(FNR==sep){sub(/\|[[:space:]]*$/, "|-|-|"); print; next}
               # Only pad rows that are still 7-field; lv-set-tags.sh may
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
        sed -e "s|{{build_command}}|$(sed_lit "$BUILD_CMD")|g" \
            -e "s|{{test_command}}|$(sed_lit "$TEST_CMD")|g" \
            -e "s|{{test_filter_flag}}|$(sed_lit "$TEST_FILTER")|g" \
            -e "s|{{test_exclude_e2e}}|$(sed_lit "$TEST_EXCLUDE_E2E")|g" \
            -e "s|{{test_only_e2e}}|$(sed_lit "$TEST_ONLY_E2E")|g" \
            -e "s|{{namespace_convention}}|$(sed_lit "$NAMESPACE_CONV")|g" \
            -e "s|{{conventions_note}}|$(sed_lit "$CONVENTIONS_NOTE")|g" \
            -e "s|{{source_dirs}}|$(sed_lit "$SOURCE_DIRS")|g" \
            -e "s|{{project_slug}}|$(sed_lit "$PROJECT_SLUG")|g" \
            -e "s|{{production_logs_url}}|$(sed_lit "$PRODUCTION_LOGS_URL")|g" \
            -e "s|{{production_url}}|$(sed_lit "$PRODUCTION_URL")|g" \
            "$f" | render_ids > "$DEST.new"

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

# ── Release branch present? ───────────────────────────────────────────────
#
# Salvaged from /wf-init, which is retired below. It was the only thing in that
# skill that worked and was not duplicated elsewhere, and it belongs here: an
# install is when a project is being set up, which is when a missing `release`
# is cheap to fix. /lv-release and /lv-deploy both assume the branch exists.
if ! git -C "$TARGET_DIR" show-ref --verify --quiet refs/heads/release 2>/dev/null; then
    echo -e "${YELLOW}  ⚠️  No local 'release' branch — /lv-release and /lv-deploy need one:${NC}"
    echo "       git checkout develop && git checkout -b release && git push origin release"
fi

# ── Retired skills ────────────────────────────────────────────────────────
#
# Deleting a skill directory from the library does NOT remove it from a client.
# The install loop below copies what exists and prunes nothing; the only prune
# in this script is the coordinator one, which strips pipeline skills from a
# coordinator and never runs for an ordinary client. So a skill dropped from the
# library stays invocable in all nine clients forever, at whatever version it
# was last deployed at — still in their skill list, still doing whatever it said.
#
# Retiring one is therefore an explicit act. A name listed here is removed from
# every client on every deploy, and stays listed: the list is the record of what
# was retired and why, and dropping a name from it would let an old copy survive
# in any client that missed the deploy that removed it.
RETIRED_SKILLS=(
    # wf-review — retired v10.6.0. It instructed the agent to write the `## Review`
    # verdict, decide Approved/Blocked, advance the plan to `ready` and commit.
    # lv-spec:566 states the opposite as non-optional ("The spawning session writes
    # `## Review`, and stamps it. Never the agent"), earned by client-b WFI-017/018,
    # and lv-review-guard.sh exists solely to catch that write. It was also orphaned
    # — nothing in skills/, scripts/, templates/ or docs/ invoked it — while staying
    # user_invocable in nine clients, and its findings.md format was the pre-schema-v4
    # FND table that lv-findings-route.sh cannot read. Review now runs inside lv-spec.
    "wf-review"

    # wf-init, wf-next — retired v12.0.0. /wf-init's job was to set TERMINAL_ROLE
    # for /wf-next to route on, and it did it with `export` inside a ```bash block:
    # a fresh shell per call, so the value never survived to the next one. No file,
    # no script and no hook ever recorded a role — /wf-next's "not set" branch was
    # the only branch reachable, and it told the user to run /wf-init. Unbuildable
    # as designed rather than broken: no skill can set an env var that outlives its
    # own call, so any fix is a rewrite wearing the old name, to restore "type
    # /wf-next instead of /lv-spec" in a library whose orchestrator already routes
    # by registry state. Neither file had been touched since April, across six
    # major versions. The 4-terminal manual mode is unaffected: no skill requires
    # a role, every one enters on a REGISTRY grep, and /lv-spec, /lv-implement and
    # /lv-test are invoked directly. wf-init's logging setup was already dead too
    # (it wrote .logs/SESSION_TIMESTAMP; .logs-utils.sh reads .logs/SESSION_ID, is
    # never deployed, and no skill calls log_start). Its one unique working
    # behaviour — the release-branch warning — is salvaged below.
    "wf-init"
    "wf-next"

    # lv-chrome-test — retired v14.34.0. An alias for `/lv-test <ID> browser`,
    # which drove criteria through the Claude in Chrome extension. The extension
    # never worked reliably for the operator, and headless Playwright already
    # covered everything it did (LVI-001). The browser mode went with it.
    "lv-chrome-test"
)

for retired in "${RETIRED_SKILLS[@]}"; do
    if [ -d "$TARGET_DIR/.claude/skills/$retired" ]; then
        rm -rf "$TARGET_DIR/.claude/skills/$retired"
        echo -e "${YELLOW}  Removed /$retired — retired from the library${NC}"
    fi
done

prune_legacy_prefix

# Copy and templatize skills
echo "Installing skills..."
mkdir -p "$TARGET_DIR/.claude/skills"
for skill_dir in "$SCRIPT_DIR/skills"/*/; do
    SKILL_NAME=$(basename "$skill_dir")
    DEST_DIR="$TARGET_DIR/.claude/skills/$SKILL_NAME"
    # The overseer rung's own skills belong to a coordinator (LVI-014); one a
    # former coordinator install left here is removed, not refreshed.
    case " $COORD_ONLY_SKILLS " in *" $SKILL_NAME "*) rm -rf "$DEST_DIR"; continue ;; esac
    mkdir -p "$DEST_DIR"

    sed -e "s|{{build_command}}|$(sed_lit "$BUILD_CMD")|g" \
        -e "s|{{test_command}}|$(sed_lit "$TEST_CMD")|g" \
        -e "s|{{test_filter_flag}}|$(sed_lit "$TEST_FILTER")|g" \
        -e "s|{{test_exclude_e2e}}|$(sed_lit "$TEST_EXCLUDE_E2E")|g" \
        -e "s|{{test_only_e2e}}|$(sed_lit "$TEST_ONLY_E2E")|g" \
        -e "s|{{namespace_convention}}|$(sed_lit "$NAMESPACE_CONV")|g" \
        -e "s|{{conventions_note}}|$(sed_lit "$CONVENTIONS_NOTE")|g" \
        -e "s|{{source_dirs}}|$(sed_lit "$SOURCE_DIRS")|g" \
        -e "s|{{project_slug}}|$(sed_lit "$PROJECT_SLUG")|g" \
        -e "s|{{production_logs_url}}|$(sed_lit "$PRODUCTION_LOGS_URL")|g" \
        -e "s|{{production_url}}|$(sed_lit "$PRODUCTION_URL")|g" \
        "$skill_dir/SKILL.md" | render_ids | atomic_write "$DEST_DIR/SKILL.md"

    echo -e "${GREEN}  Installed /$(basename "$skill_dir")${NC}"
done

install_referenced_docs "$TARGET_DIR/.claude/skills" "$TARGET_DIR/.claude/docs"

# Install local env script (only if local_deploy_command is set)
if [ -n "$LOCAL_DEPLOY" ]; then
    sed -e "s|{{local_start_command}}|$(sed_lit "$LOCAL_START")|g" \
        -e "s|{{local_deploy_command}}|$(sed_lit "$LOCAL_DEPLOY")|g" \
        -e "s|{{local_stop_command}}|$(sed_lit "$LOCAL_STOP")|g" \
        -e "s|{{project_slug}}|$(sed_lit "$PROJECT_SLUG")|g" \
        "$SCRIPT_DIR/templates/on-implement-commit.sh" | atomic_write "$TARGET_DIR/.claude/on-implement-commit.sh"
    chmod +x "$TARGET_DIR/.claude/on-implement-commit.sh"
    echo -e "${GREEN}  Installed .claude/on-implement-commit.sh${NC}"

    # Gitignore local-env runtime files. Every file on-implement-commit.sh
    # writes belongs here: the run pid and run log arrived with the detached
    # launch (LVI-037) without being added, and lv-test's pre-merge `git add -A`
    # committed the pid onto three feature branches (LVI-015/018/020).
    GITIGNORE="$TARGET_DIR/.gitignore"
    for pattern in ".claude/local-env.timestamp" ".claude/local-env.pid" ".claude/local-env.log" \
                   ".claude/local-env-run.pid" ".claude/local-env-run.log"; do
        if ! grep -qF "$pattern" "$GITIGNORE" 2>/dev/null; then
            echo "$pattern" >> "$GITIGNORE"
        fi
    done
    echo -e "${GREEN}  Updated .gitignore with local-env runtime files${NC}"
else
    echo -e "${YELLOW}  local_deploy_command not set — skipping local env install${NC}"
fi

# Install verify trigger script (always — verify agent is core to the pipeline)
atomic_install "$SCRIPT_DIR/templates/on-verify-trigger.sh" "$TARGET_DIR/.claude/on-verify-trigger.sh" +x
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
# lv-worktree-sparse.sh states where that leads: "Excluding a file you also
# write is not a stricter policy than tracking it; it is a broken one." The
# same is true of tracking it. See docs/untracked-harness.md.
#
# NOT ignored, deliberately: levain.yml (the project's own config),
# .claude/workflow-version (the one-line stamp saying which harness a commit
# was made under), WORKFLOW.md (the entry contract), and plans/ + bugs/.
#
# The `lv-` prefix on the skills glob is load-bearing: a project's own skills
# sit in the same directory and are its source, not ours.
for pattern in \
    ".claude/skills/lv-*/" \
    ".claude/skills/wf-*/" \
    ".claude/docs/" \
    ".claude/workflow.md" \
    ".claude/workflow-source" \
    ".claude/settings.local.json" \
    ".claude/on-implement-commit.sh" \
    ".claude/on-verify-trigger.sh" \
    "scripts/lv-exec.sh" \
    "scripts/wf-exec.sh" \
    "scripts/version-map.txt" \
    "scripts/lv-prune-versions.sh" \
    "scripts/v*/" \
    "scripts/gen/" \
    "scripts/current" ; do
    if ! grep -qxF "$pattern" "$GITIGNORE" 2>/dev/null; then
        echo "$pattern" >> "$GITIGNORE"
        HARNESS_IGNORED=$((HARNESS_IGNORED + 1))
    fi
done
if [ "$HARNESS_IGNORED" -gt 0 ]; then
    echo -e "${GREEN}  Added $HARNESS_IGNORED generated-harness pattern(s) to .gitignore${NC}"
    if git -C "$TARGET_DIR" ls-files --error-unmatch scripts/lv-exec.sh >/dev/null 2>&1; then
        echo -e "${YELLOW}  The harness is still TRACKED here. To finish the migration:${NC}"
        # --ignore-unmatch is not optional: `git rm` is atomic, so a single
        # pathspec matching nothing tracked (a client that already ignores
        # .claude/skills/*, as app did) aborts the WHOLE command and untracks
        # nothing — silently, if stderr is redirected.
        echo "    git rm -r --cached --quiet --ignore-unmatch \\"
        echo "      .claude/skills/lv-* .claude/workflow.md \\"
        echo "      .claude/on-implement-commit.sh .claude/on-verify-trigger.sh \\"
        echo "      scripts/lv-exec.sh scripts/version-map.txt scripts/lv-prune-versions.sh \\"
        echo "      scripts/v* scripts/gen scripts/current"
        echo "    git commit -m 'chore: stop tracking the generated workflow harness'"
    fi
fi

# Feature worktrees.
#
# `feature-branches/` is the workflow's own convention — lv-worktree-sparse.sh
# creates it — so ignoring it is the harness's job, not each project's. Left
# out, it sits untracked on develop from the moment the first plan gets a
# worktree, and a `git add -A` on develop commits an entire feature worktree
# into the planning branch (WFI-032, same class as WFI-007).
if ! grep -qF "feature-branches/" "$GITIGNORE" 2>/dev/null; then
    echo "feature-branches/" >> "$GITIGNORE"
    echo -e "${GREEN}  Added feature-branches/ to .gitignore${NC}"
fi

# Release/deploy worktrees.
#
# `release-branches/` is the same idea as `feature-branches/` above, but
# permanent rather than per-plan: `/lv-release` and `/lv-deploy` pin `release`
# and `main` to their own worktrees here (`lv-worktree-pin.sh`) instead of
# borrowing the shared develop checkout. See docs/release-worktrees.md. Left
# out of .gitignore, the same class of accident applies — a `git add -A` on
# develop would commit an entire pinned worktree into the planning branch.
if ! grep -qF "release-branches/" "$GITIGNORE" 2>/dev/null; then
    echo "release-branches/" >> "$GITIGNORE"
    echo -e "${GREEN}  Added release-branches/ to .gitignore${NC}"
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
# finished plan until step 6 of lv-implement overwrites it — and that overwrite
# then shows as a modification to a tracked file, which the next `git add -u`
# commits and the next merge propagates. The loop feeds itself.
#
# Per docs/worktrees.md this is the gitignored row: the harness generates it,
# and a session reads it off its own disk. lv-implement writes it into the
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
# Where the hooks live, which is NOT always "$TARGET_DIR/.git/hooks".
#
# In a git WORKTREE, `.git` is a FILE holding a `gitdir:` pointer, so
# `$TARGET_DIR/.git/hooks/post-commit` is not a path at all and `cp` fails with
# "Not a directory". client-a's WFI-191: /lv-release step 5a's documented
# recovery ran install.sh against a dedicated release worktree, died right
# here, and left the harness HALF INSTALLED — .claude/skills and
# .claude/orchestrator written, lv-exec.sh and scripts/v*/ never reached. The
# recheck still said HARNESS MISSING, with no lv-* script on disk to run. A
# project with a release worktree hits that on every release.
#
# Hooks are shared by every worktree, so the right directory is always the
# COMMON git dir. --path-format is git 2.31+; older git returns a path relative
# to the worktree, which is resolved by hand.
GIT_COMMON_DIR=$(git -C "$TARGET_DIR" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)
if [ -z "$GIT_COMMON_DIR" ]; then
    GIT_COMMON_DIR=$(git -C "$TARGET_DIR" rev-parse --git-common-dir 2>/dev/null || true)
    case "$GIT_COMMON_DIR" in
        "")  ;;
        /*)  ;;
        *)   GIT_COMMON_DIR="$TARGET_DIR/$GIT_COMMON_DIR" ;;
    esac
fi
[ -n "$GIT_COMMON_DIR" ] || GIT_COMMON_DIR="$TARGET_DIR/.git"
# And it is a WARNING when it fails, not the end of the install.
#
# The other half of WFI-191: the hook is a convenience — it triggers the verify
# agent — and `scripts/lv-exec.sh` is the harness itself. Under `set -e` this
# block aborted before the dispatcher was ever written, so a recoverable
# problem with an optional file cost the project every lv-* script. Whatever
# goes wrong here, the install continues and says what was lost.
#
# post-merge and post-checkout (LVI-032) rebuild the develop checkout's
# git-ignored derived files from levain.yml's derivedCommand. They are
# installed the same way, and they are no-ops in a project that sets no
# derivedCommand.
install_git_hook() {
    local name="$1" src="$SCRIPT_DIR/templates/hooks/$1" hook="$GIT_COMMON_DIR/hooks/$1"
    mkdir -p "$GIT_COMMON_DIR/hooks" || return 1
    if [ ! -f "$hook" ]; then
        cp "$src" "$hook" || return 1
        chmod +x "$hook" || return 1
        echo -e "${GREEN}  Installed $name hook ($hook)${NC}"
    elif ! grep -q "claude-workflow" "$hook"; then
        # Not ours. Keep it — clobbering a project's own hook is not our call.
        cp "$hook" "$hook.pre-workflow" || return 1
        cp "$src" "$hook" || return 1
        chmod +x "$hook" || return 1
        echo -e "${YELLOW}  Replaced a non-workflow $name hook${NC}"
        echo -e "${YELLOW}  The original is at $hook.pre-workflow — merge it back if you need it${NC}"
    elif cmp -s "$src" "$hook"; then
        echo -e "${YELLOW}  $name hook already up to date — skipping${NC}"
    else
        cp "$src" "$hook" || return 1
        chmod +x "$hook" || return 1
        echo -e "${GREEN}  Updated $name hook ($hook)${NC}"
    fi
    return 0
}
if ! install_git_hook post-commit; then
    echo -e "${YELLOW}  Could not install the post-commit hook at $GIT_COMMON_DIR/hooks/post-commit${NC}"
    echo -e "${YELLOW}  The verify agent will not be triggered automatically in this checkout.${NC}"
    echo -e "${YELLOW}  Continuing — the rest of the harness does not depend on it.${NC}"
fi
for _gh in post-merge post-checkout; do
    if ! install_git_hook "$_gh"; then
        echo -e "${YELLOW}  Could not install the $_gh hook at $GIT_COMMON_DIR/hooks/$_gh${NC}"
        echo -e "${YELLOW}  derivedCommand will not rebuild the develop checkout's derived files on merge or checkout.${NC}"
    fi
done

# Install the Claude Code session hooks (state rehydration after compaction).
#
# These are CLAUDE CODE hooks in .claude/settings.json — a different mechanism
# from the git hook above, and the reason both live here is that they are the
# only two places the harness gets to run without a skill asking it to.
#
# SessionStart(compact) is the load-bearing one: it is the only event whose
# output reaches the MODEL after a compaction. PostCompact's stdout is shown to
# the human and nothing else. See docs/rehydration.md and lv-rehydrate.sh.
#
# settings.json is the client's file, not ours — it may hold their permissions,
# env and their own hooks. So this MERGES rather than overwriting; the rules are
# in templates/hooks/settings-merge.py, which is where to look before changing
# what gets written.
SETTINGS="$TARGET_DIR/.claude/settings.json"
# ── …but only in the MAIN worktree ────────────────────────────────────────
#
# settings.json is TRACKED (see the note below this block), and this merge
# writes it. In the main worktree that is fine: the write is committed there
# and git carries it into every worktree afterwards.
#
# In a LINKED worktree it is the collision lv-worktree-sparse.sh names —
# "excluding a file you also write is not a stricter policy than tracking it;
# it is a broken one" — with `tracked` in place of `excluded`. Writing a
# tracked path leaves that worktree dirty against its own branch, and the
# dirt is invisible until something tries to merge.
#
# client-b WFI-029: /lv-deploy step 6 runs lv-harness-restore.sh inside
# release-branches/main, which re-runs this installer there; the merge wrote
# the promote-guard block that the incoming `release` ALSO carried. Step 7's
# `git merge -X theirs --no-ff release` then aborted — "Your local changes to
# .claude/settings.json would be overwritten by merge" — AFTER
# lv-deploy-guard.sh --arm had already succeeded, leaving main armed but
# unmerged. The local change was byte-identical to `git show
# release:.claude/settings.json`; the merge could not know that, and refused.
#
# So: in a linked worktree the hooks arrive the way every other tracked file
# does, through git. Nothing is lost by not writing them here, and the case
# where they would genuinely be absent — an untracked settings.json — is the
# one the warning below already covers.
IS_LINKED_WORKTREE=0
if git -C "$TARGET_DIR" rev-parse --git-dir >/dev/null 2>&1; then
    _gd=$(cd "$TARGET_DIR" && cd "$(git rev-parse --git-dir)" && pwd -P)
    _gc=$(cd "$TARGET_DIR" && cd "$(git rev-parse --git-common-dir)" && pwd -P)
    [ "$_gd" = "$_gc" ] || IS_LINKED_WORKTREE=1
fi
REHYDRATE_CMD="\"\$CLAUDE_PROJECT_DIR\"/scripts/lv-exec.sh lv-rehydrate.sh --hook"
GUARD_CMD="\"\$CLAUDE_PROJECT_DIR\"/scripts/lv-exec.sh lv-guard-write.sh"
PROMOTE_GUARD_CMD="\"\$CLAUDE_PROJECT_DIR\"/scripts/lv-exec.sh lv-guard-promote.sh"
GUARD_LINE="    PreToolUse    matcher Edit|Write|NotebookEdit  → $GUARD_CMD"
PROMOTE_GUARD_LINE="    PreToolUse    matcher Bash                    → $PROMOTE_GUARD_CMD"
BASELINE_GUARD_CMD="\"\$CLAUDE_PROJECT_DIR\"/scripts/lv-exec.sh lv-guard-baseline.sh"
BASELINE_GUARD_LINE="    PreToolUse    matcher *                       → $BASELINE_GUARD_CMD  (fail closed for workers; coordinator WFI-005)"
if [ "$IS_LINKED_WORKTREE" -eq 1 ]; then
    echo -e "${YELLOW}  Linked worktree — leaving .claude/settings.json to git (WFI-029)${NC}"
elif command -v python3 >/dev/null 2>&1; then
    # `|| true` for the same reason the git hook above is non-fatal (WFI-191):
    # a merge that dies must not abort the install before scripts/lv-exec.sh is
    # written. An empty result falls through to the catch-all below and warns.
    SETTINGS_RESULT=$(SETTINGS_PATH="$SETTINGS" REHYDRATE_CMD="$REHYDRATE_CMD" \
        GUARD_CMD="$GUARD_CMD" PROMOTE_GUARD_CMD="$PROMOTE_GUARD_CMD" \
        BASELINE_GUARD_CMD="$BASELINE_GUARD_CMD" \
        LV_HOOK_CMD="$SCRIPT_DIR/scripts/v2.00/lv-hook.sh" CLAUDE_PROJECT_DIR="$TARGET_DIR" \
        python3 "$SCRIPT_DIR/templates/hooks/settings-merge.py") || true
    case "$SETTINGS_RESULT" in
        created)      echo -e "${GREEN}  Created .claude/settings.json with the rehydration and guard hooks${NC}" ;;
        updated)      echo -e "${GREEN}  Updated .claude/settings.json rehydration and guard hooks${NC}" ;;
        unchanged)    echo -e "${YELLOW}  .claude/settings.json hooks already up to date — skipping${NC}" ;;
        unparseable:*)
            echo -e "${YELLOW}  .claude/settings.json is not valid JSON (${SETTINGS_RESULT#unparseable:})${NC}"
            echo -e "${YELLOW}  Left untouched. Fix it and re-run, or add the hooks by hand:${NC}"
            echo "    SessionStart  matcher compact|clear|resume  → $REHYDRATE_CMD session-start 2>/dev/null || true"
            echo "    PostCompact   matcher manual|auto           → $REHYDRATE_CMD post-compact 2>/dev/null || true"
            echo "$GUARD_LINE"
            echo "$PROMOTE_GUARD_LINE"
            echo "$BASELINE_GUARD_LINE" ;;
        "")           echo -e "${YELLOW}  .claude/settings.json merge failed (see the error above) — hooks NOT installed${NC}"
                      echo -e "${YELLOW}  Continuing; add them by hand (see docs/rehydration.md):${NC}"
                      echo "$GUARD_LINE"
                      echo "$PROMOTE_GUARD_LINE"
                      echo "$BASELINE_GUARD_LINE" ;;
        *)            echo -e "${YELLOW}  .claude/settings.json: unexpected result '$SETTINGS_RESULT'${NC}" ;;
    esac
else
    echo -e "${YELLOW}  python3 not found — skipping .claude/settings.json hooks${NC}"
    echo -e "${YELLOW}  Add them by hand (see docs/rehydration.md):${NC}"
    echo "    SessionStart  matcher compact|clear|resume  → $REHYDRATE_CMD session-start 2>/dev/null || true"
    echo "    PostCompact   matcher manual|auto           → $REHYDRATE_CMD post-compact 2>/dev/null || true"
    echo "$GUARD_LINE"
    echo "$PROMOTE_GUARD_LINE"
    echo "$BASELINE_GUARD_LINE"
fi

# .claude/settings.json stays TRACKED, deliberately.
#
# It is not generated harness — the merge above touches two keys and leaves the
# project's own permissions and hooks alone — and it must be tracked for a
# reason specific to this workflow: git materialises tracked files into a new
# worktree, and an untracked settings.json means every feature worktree runs
# WITHOUT the rehydration hooks. That is exactly the session most likely to
# compact mid-implementation.
if [ "$IS_LINKED_WORKTREE" -eq 0 ] && [ -f "$SETTINGS" ] \
   && ! git -C "$TARGET_DIR" ls-files --error-unmatch ".claude/settings.json" >/dev/null 2>&1; then
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
# Feature branches still never see it: lv-worktree-sparse.sh excludes plans/**
# from every feature worktree, so registry churn cannot reach a feature branch
# or arrive as a conflict when one merges back.
GITIGNORE="$TARGET_DIR/.gitignore"
if grep -qF "plans/REGISTRY.md" "$GITIGNORE" 2>/dev/null; then
    grep -vF "plans/REGISTRY.md" "$GITIGNORE" > "$GITIGNORE.tmp" && mv "$GITIGNORE.tmp" "$GITIGNORE"
    echo -e "${GREEN}  Removed plans/REGISTRY.md from .gitignore — it is tracked now${NC}"
fi

# Checked on EVERY deploy, not only the one that removes the ignore rule.
#
# This test used to be nested inside the block above, so it ran exactly once
# per client — on the single deploy that un-ignored the registry — and never
# again. Un-ignoring a file does not add it, so a client that missed that one
# message, or read it in a deploy log nobody kept, stayed untracked forever
# with every later deploy silent about it. client-i did: its ignore rule
# came off in `chore: stop tracking the generated workflow harness`, and the
# registry then sat untracked across every deploy from v5.0.15 to v6.9.0.
#
# The settings.json check above is unconditional for the same reason. A
# one-shot warning about a persistent condition is a warning that is wrong
# more often than it is right.
if [ -f "$REGISTRY_DEST" ] \
   && git -C "$TARGET_DIR" rev-parse --git-dir >/dev/null 2>&1 \
   && ! git -C "$TARGET_DIR" ls-files --error-unmatch plans/REGISTRY.md >/dev/null 2>&1; then
    echo -e "${YELLOW}  plans/REGISTRY.md is untracked — the pipeline's state machine is${NC}"
    echo -e "${YELLOW}  not in git, and a lost develop worktree takes it with it:${NC}"
    echo "    git add plans/REGISTRY.md && git commit -m 'chore: track the plan registry'"
fi

# Install workflow scripts — immutable builds (v9.0+).
#
# Each scripts/v*/ in the library is a complete, frozen snapshot, and the
# unversioned dispatcher (scripts/lv-exec.sh) routes plans to the right one via
# scripts/version-map.txt. That much is unchanged. What changed in v9.0.0 is
# WHERE the client's copy lands: a build directory named for this deploy, which
# is published by one rename and then never written again. Nothing resolves it
# until scripts/current is flipped. See docs/atomic-deploy.md.
echo "Installing scripts..."
mkdir -p "$TARGET_DIR/scripts"
gen_stage_begin

# Template each versioned snapshot into the staging build.
for version_dir in "$SCRIPT_DIR/scripts"/v*/; do
    [ -d "$version_dir" ] || continue
    folder_name=$(basename "$version_dir")
    DEST_VDIR="$GEN_STAGE/$folder_name"
    mkdir -p "$DEST_VDIR"
    for script in "$version_dir"/lv-*.sh; do
        [ -f "$script" ] || continue
        # ${script##*/} rather than basename, and one chmod for the folder
        # rather than one per file: this loop runs ~80 times per client and
        # deploy-all.sh runs it for every client.
        DEST="$DEST_VDIR/${script##*/}"
        sed -e "s|{{project_slug}}|$(sed_lit "$PROJECT_SLUG")|g" \
            -e "s|{{production_logs_url}}|$(sed_lit "$PRODUCTION_LOGS_URL")|g" \
            -e "s|{{production_url}}|$(sed_lit "$PRODUCTION_URL")|g" \
            "$script" > "$DEST"
    done
    # The extension hooks' neutral defaults (lv-hook.sh). Copied, not
    # templated: a pack reads them for their kind, and nothing in them is
    # per-project.
    [ -d "$version_dir/hooks.default" ] && cp -R "$version_dir/hooks.default" "$DEST_VDIR/"
    chmod +x "$DEST_VDIR"/*.sh 2>/dev/null || true
    echo -e "${GREEN}  Staged $folder_name/ ($(ls "$DEST_VDIR" | wc -l | tr -d ' ') scripts)${NC}"
done

# No stale-script pruning pass any more, and none is possible: a build starts
# empty, so a lv-*.sh the library no longer ships simply is not in it. That
# pass existed because the old layout wrote into a folder it did not own the
# whole contents of — four clients carried a deleted lv-infra-sync.sh from
# August until v6.7.0 because deploy had no way to remove one. Residue is now
# ruled out by construction rather than swept up afterwards.

gen_publish

# Dispatcher + pruning tool + version map — unversioned, and installed AFTER
# the flip. An old dispatcher paired with a new pointer resolves correctly (it
# ignores scripts/current and uses the legacy folder, which is still the old
# harness); a new dispatcher paired with an old pointer would not.
for f in lv-exec.sh lv-prune-versions.sh wf-exec.sh; do
    atomic_install "$SCRIPT_DIR/scripts/$f" "$TARGET_DIR/scripts/$f" +x
    echo -e "${GREEN}  Installed scripts/$f${NC}"
done
atomic_install "$SCRIPT_DIR/scripts/version-map.txt" "$TARGET_DIR/scripts/version-map.txt"
echo -e "${GREEN}  Installed scripts/version-map.txt${NC}"

gen_retire

# Gitignore workflow runtime files
GITIGNORE="$TARGET_DIR/.gitignore"
for pattern in ".wf-claim"; do
    if ! grep -qF "$pattern" "$GITIGNORE" 2>/dev/null; then
        echo "$pattern" >> "$GITIGNORE"
    fi
done

# Stamp workflow version into the target project
printf '%s\n' "$WORKFLOW_VERSION" | atomic_write "$TARGET_DIR/.claude/workflow-version"
echo -e "${GREEN}  Stamped workflow version $WORKFLOW_VERSION → .claude/workflow-version${NC}"

# Record where this harness came from, so a client that loses it can ask the
# library for a fresh one instead of digging a stale one out of its own history.
#
# client-a's WFI-119: the reflog recovery found the newest ref that still
# TRACKED the harness — necessarily a ref from before the v5.0.0 untrack commit,
# i.e. a v3.3.0-era harness — and installed it into a project stamped 6.2.1, with
# no version check and a success message either way. Three major versions of
# stale lv-* scripts, silently. Re-running the installer is the correct recovery
# whenever the library is reachable; this file is what makes it reachable.
#
# Untracked, like the rest of the generated harness: it is a local fact about
# this machine, not something to carry to another clone.
printf '%s\n' "$SCRIPT_DIR" | atomic_write "$TARGET_DIR/.claude/workflow-source"

# WORKFLOW.md at the project root — the entry-point contract for anyone (or
# anything) that lands in this repo without prior context: how work enters the
# pipeline, which hooks fire automatically, and the lv-orchestrate.sh exit codes
# an external process needs in order to drive a plan.
# Regenerated on every install so it can't drift from the installed version.
sed -e "s|{{project_slug}}|$(sed_lit "$PROJECT_SLUG")|g" \
    -e "s|{{workflow_version}}|$(sed_lit "$WORKFLOW_VERSION")|g" \
    "$SCRIPT_DIR/templates/WORKFLOW.md" | render_ids | atomic_write "$TARGET_DIR/WORKFLOW.md"
echo -e "${GREEN}  Installed WORKFLOW.md (project-root entry point)${NC}"

# Seed WORKFLOW-ISSUES.md so the reporting channel is discoverable before the
# first problem, not after. Created via lv-issue.sh itself (--count is a no-op
# read that writes the header when missing) so the format has exactly one owner
# and can't drift between the script and the installer.
if [ ! -f "$TARGET_DIR/WORKFLOW-ISSUES.md" ]; then
    ( cd "$TARGET_DIR" && ./scripts/lv-exec.sh lv-issue.sh --count >/dev/null 2>&1 ) || true
    [ -f "$TARGET_DIR/WORKFLOW-ISSUES.md" ] \
      && echo -e "${GREEN}  Seeded WORKFLOW-ISSUES.md (harness problems get reported here)${NC}"
fi

# ── Propagate to feature worktrees ───────────────────────────────────────────
# Resolve a worktree's plan WF stamp → script_folder using the same algorithm
# as lv-exec.sh. Only that folder (plus the unversioned dispatcher + map) gets
# copied into the worktree — so an in-flight plan keeps running the scripts it
# was built against, even after we publish newer generations.
# A version is dotted digits and nothing else — the same test lv-exec.sh:73
# makes, and for the same reason. `sort -V` places any non-numeric string
# ABOVE every numeric version, so an unstamped marker like the registry's
# em-dash satisfies EVERY row of version-map.txt and resolves to the NEWEST
# folder — the precise opposite of what the WF column exists to guarantee.
# This copy of the walk shipped without the test; a worktree whose plan row
# carried `—` was handed the newest generation rather than the baseline.
is_version() { [[ "$1" =~ ^[0-9]+(\.[0-9]+)*$ ]]; }

resolve_script_folder() {
    local wf="$1"
    local map="$TARGET_ABS/scripts/version-map.txt"
    is_version "$wf" || wf="0.00"
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

# A label is not a path any more. Resolve one the same way lv-exec.sh does:
# the published build first, the legacy folder as the fallback that carries a
# client across its first gen-era deploy.
resolve_script_dir() {
    local label="$1" build=""
    [ -n "$label" ] || { echo ""; return; }
    [ -f "$TARGET_ABS/scripts/current" ] && build=$(tr -d '[:space:]' < "$TARGET_ABS/scripts/current")
    if [ -n "$build" ] && [ -d "$TARGET_ABS/scripts/gen/$build/$label" ]; then
        echo "$TARGET_ABS/scripts/gen/$build/$label"
    elif [ -d "$TARGET_ABS/scripts/$label" ]; then
        echo "$TARGET_ABS/scripts/$label"
    else
        echo ""
    fi
}

if git -C "$TARGET_DIR" rev-parse --git-dir &>/dev/null; then
    echo "Updating feature worktrees..."
    # `pwd -P`, not `pwd`. This is compared against the paths `git worktree
    # list` reports, and git reports the PHYSICAL path. Under a symlinked
    # prefix — /var → /private/var on macOS, or any project reached through a
    # symlink — the logical form never matches, so install.sh sees its own
    # target in the list, decides it is a foreign feature worktree, and runs
    # lv-worktree-harness.sh over it. That step deliberately installs only
    # lv-exec.sh (a feature worktree resolves version-map.txt and scripts/v*/
    # from the main checkout), so it strips back out the very files the install
    # had just written — an install that reports success and leaves the target
    # unable to dispatch.
    TARGET_ABS="$(cd "$TARGET_DIR" && pwd -P)"
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
                wt_plan_id=$(echo "$wt_branch" | grep -oE "($TARGET_PLAN_RE)-[0-9]+" | head -1 || true)
                wt_wf=""
                if [ -n "$wt_plan_id" ] && [ -f "$TARGET_ABS/plans/REGISTRY.md" ]; then
                    row=$(grep "^| ${wt_plan_id} " "$TARGET_ABS/plans/REGISTRY.md" | head -1 || true)
                    # WF column is field $8 in 7-column registry (ID|Slug|State|Priority|Branch|Updated|WF)
                    [ -n "$row" ] && wt_wf=$(echo "$row" | awk -F'|' '{print $8}' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
                fi
                wt_folder=$(resolve_script_folder "$wt_wf")
                wt_dir=$(resolve_script_dir "$wt_folder")

                # Re-run sparse configuration first: it repairs a worktree set
                # up by an older pattern list, and clears the deploy copies
                # this step used to leave behind.
                if [ -n "$wt_dir" ] && [ -x "$wt_dir/lv-worktree-sparse.sh" ]; then
                    "$wt_dir/lv-worktree-sparse.sh" "$wt_path" >/dev/null 2>&1 || true
                fi

                # Put the three must-exist paths on the worktree's disk.
                #
                # They are gitignored now, so this is the ONLY way they arrive
                # — git no longer materialises them, and nothing reconciles
                # them afterwards because an ignored file cannot be dirty,
                # cannot conflict, and cannot abort a merge. Everything else
                # workflow-owned resolves from the MAIN worktree.
                if [ -n "$wt_dir" ] && [ -x "$wt_dir/lv-worktree-harness.sh" ]; then
                    "$wt_dir/lv-worktree-harness.sh" "$wt_path" >/dev/null 2>&1 || true
                fi

                echo -e "  ${GREEN}Updated $(basename "$wt_path") (skills + lv-exec.sh; scripts/${wt_folder:-none} resolved from develop, WF=${wt_wf:-0.00})${NC}"
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
sed -e "s|{{build_command}}|$(sed_lit "$BUILD_CMD")|g" \
    -e "s|{{test_command}}|$(sed_lit "$TEST_CMD")|g" \
    -e "s|{{source_dirs}}|$(sed_lit "$SOURCE_DIRS")|g" \
    "$SCRIPT_DIR/claude-md/workflow-snippet.md" | render_ids | atomic_write "$WORKFLOW_MD"
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
# v5.0.0 — scripts/v*/, .claude/skills/lv-*/, the hooks. A handful of paths are
# deliberately NOT: the project's config, the entry contract, the version
# stamp, the plan template. Those are tracked, so a deploy left the client's
# develop dirty and walked away.
#
# That is not cosmetic. The next worker into that repo reads an uncommitted
# `.claude/workflow-version` and a modified `levain.yml` as somebody
# else's work in progress and has to decide what to do about it — client-a's
# WFI-131 filed exactly that, mid-plan, and worked around it by leaving the
# changes alone. Meanwhile the files are on the shared develop index, where the
# next `lv-commit.sh` from any live worker would have carried them under that
# plan's message.
#
# So the deploy owns its own changes: pathspec-scoped, its own commit, nothing
# else swept in. `git commit -- <paths>` commits those paths from the working
# tree and leaves the rest of the index alone, which is what makes it safe to
# run while other workers have things staged.
if $INSTALL_COMMIT && git -C "$TARGET_DIR" rev-parse --verify --quiet HEAD >/dev/null 2>&1; then
    DEPLOY_PATHS=()
    for p in levain.yml WORKFLOW.md .claude/workflow-version plans/TEMPLATE.md CLAUDE.md .gitignore; do
        git -C "$TARGET_DIR" ls-files --error-unmatch -- "$p" >/dev/null 2>&1 || continue
        git -C "$TARGET_DIR" diff --quiet -- "$p" 2>/dev/null || DEPLOY_PATHS+=("$p")
    done
    # A staged rename shows no working-tree diff on either side; name both.
    $CONFIG_RENAMED && DEPLOY_PATHS+=(levain.yml claude-workflow.yml)

    if [ ${#DEPLOY_PATHS[@]} -gt 0 ]; then
        DEPLOY_BRANCH=$(git -C "$TARGET_DIR" branch --show-current 2>/dev/null || true)
        # A promotion branch is not the deploy's to commit to while develop
        # exists. Every human approval of a release or deploy is scoped to the
        # tip of `release`/`main` it was given for; a sync commit there moves
        # that tip, the approval lapses, and the operator is asked the same
        # question again over a batch whose code did not change (coordinator
        # WFI-010, WFI-037). The sync belongs on develop and reaches the
        # promotion branches with the next real batch.
        DEPLOY_ON_PROMOTION=false
        case "$DEPLOY_BRANCH" in
            release) DEPLOY_ON_PROMOTION=true ;;
            main|master)
                git -C "$TARGET_DIR" rev-parse --verify --quiet refs/heads/develop >/dev/null 2>&1 \
                    && DEPLOY_ON_PROMOTION=true ;;
        esac
        if $DEPLOY_ON_PROMOTION; then
            echo -e "${YELLOW}  Left ${DEPLOY_PATHS[*]} uncommitted — checkout is on '$DEPLOY_BRANCH', a promotion${NC}"
            echo -e "${YELLOW}    branch; a commit there would lapse a pending approval. Land them from develop.${NC}"
            DEPLOY_BRANCH="(promotion)"
        fi
        case "$DEPLOY_BRANCH" in
            "(promotion)") ;;
            develop|main|master)
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
# The skill list is generated from the installed skills' own files (LVI-012),
# so it cannot drift the way the hand-written list here did.
bash "$SCRIPT_DIR/scripts/v2.00/lv-skills.sh" --dir "$TARGET_DIR/.claude/skills" || true
echo ""
# Report the project's actual orchestrator state, not the template's default.
# A project stood up by copying another's levain.yml, or by skipping
# install/attended.md, otherwise learns it is off only when --daemon refuses.
ORCH_ENABLED=$(awk '
    /^orchestrator:/ { in_block = 1; next }
    in_block && /^[^[:space:]#]/ { in_block = 0 }
    in_block && /^  enabled:/ { v = $2; gsub(/["'\'']/, "", v); print v; exit }
' "$CONFIG_FILE")
echo "Orchestrated mode:"
if [ "$ORCH_ENABLED" = "true" ]; then
    echo -e "  ${GREEN}orchestrator.enabled: true${NC} — start the daemon in a terminal of its own:"
    echo "    scripts/lv-exec.sh lv-orchestrate.sh --daemon"
else
    echo -e "  ${YELLOW}orchestrator.enabled is not true in levain.yml — the daemon will refuse to start.${NC}"
    echo "  It ships off on purpose: workers run with --dangerously-skip-permissions."
    echo "  Ask the owner whether to turn it on (install/attended.md). Preview first:"
    echo "    scripts/lv-exec.sh lv-orchestrate.sh --sweep --dry-run"
fi
echo ""
echo "Start with your first idea: /lv-brainstorm <what you want to build or fix>"
echo "  /lv-tray shows the pipeline and the next action; /lv-help lists every skill."
echo "  Guided setup, and the rungs above this one: read START.md in the library ($SCRIPT_DIR)."
echo "See WORKFLOW.md in the project root for the full entry-point contract."
