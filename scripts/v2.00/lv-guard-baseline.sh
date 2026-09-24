#!/usr/bin/env bash
# lv-guard-baseline.sh — PreToolUse guard: the permission baseline every
# unattended worker runs inside.
#
# Wired to PreToolUse on every tool by templates/hooks/settings-merge.py.
# Reads the hook payload on stdin and exits 2 (block, reason to the model)
# when the call breaks a baseline rule. Exits 0 otherwise.
#
# WHY THIS EXISTS (coordinator WFI-005)
#
# lv-spawn.sh starts every worker with `claude -p --dangerously-skip-permissions`.
# Until this guard, no client had a single deny rule. The only hooks were
# lv-guard-write.sh (claimed artifacts, fails open) and lv-guard-promote.sh
# (release/main, only while their gate is open). A worker could read the
# secrets archive, set Fly secrets, destroy a volume or force-push, and the
# only thing between it and that was a human pausing the pipeline. The
# pipeline is meant to stop for a person only when security needs one, so
# the security goes here, into code, and the pauses can come out.
#
# Proven 2026-09-23 on Claude Code 2.1.280: under
# --dangerously-skip-permissions, both a PreToolUse exit 2 and a
# permissions.deny rule still refuse the call. settings-merge.py installs both
# layers: this hook for the full rule set, deny rules for secret reads.
#
# WHO IT APPLIES TO
#
# Only unattended workers: LV_UNATTENDED=1, which lv-spawn.sh exports into the
# worker's environment and the hook inherits. An interactive session is the
# operator's own, and it already has Claude Code's permission prompts. The
# check for that is the first line of work below, so an interactive session
# pays one env test per tool call and nothing else.
#
# FAIL CLOSED, FOR WORKERS
#
# The opposite of lv-guard-write.sh, on purpose. That guard protects against a
# collision, and a broken guard there would brick the editor. This one is the
# only control on an agent with every permission, so for a worker any doubt
# (no python3, an unreadable payload, a crash) refuses. The hook command in
# settings.json turns any non-zero exit into 2 for a worker (see
# settings-merge.py), so a crash here refuses as well.
#
# LOOSENING A RULE
#
# A client lifts a rule only in its own claude-workflow.yml, and only with a
# recorded reason. All four keys are required; a partial block lifts nothing:
#
#   permissionBaseline:
#     allow:
#       - provider-shell
#     reason: "deploy smoke test needs fly ssh on staging"
#     set_by: "Marc Blais"
#     set_on: 2026-09-23
#
# Rules (the ids `allow` takes):
#   secret-read       reading secret material: .env files, private keys, the
#                     secrets-tool archive, credential stores
#   secrets-tool-value      `secrets-tool value`, the one command that prints a secret
#   provider-secrets  fly secrets set/import/unset, gh secret set/delete
#   provider-shell    fly ssh / fly console into a running app
#   provider-destroy  destroying Fly apps, volumes, machines or storage;
#                     deleting, archiving or re-publishing a GitHub repo
#   force-push        git push --force/-f/--force-with-lease/--mirror/--delete,
#                     or a +refspec or :branch refspec
#   history-rewrite   git filter-repo, git filter-branch
#   rm-outside        rm -r on a path outside the worktree and temp dirs
#   pipe-to-shell     curl or wget piped into a shell or interpreter
#
# This is a guard against a mistaken or misled agent, not a sandbox against a
# hostile one. A command assembled at run time (eval, base64, variables) can
# get past a text match. Deny rules and the provider's own scoping remain the
# deeper layers.
#
# Exit 0 allow, 2 block.

set -uo pipefail

[ "${LV_UNATTENDED:-}" = "1" ] || exit 0

refuse() { printf 'permission baseline: %s\n' "$1" >&2; exit 2; }

command -v python3 >/dev/null 2>&1 || refuse "python3 is missing, so the call cannot be checked; refusing (fail closed)"

payload=$(cat 2>/dev/null) || refuse "the hook payload could not be read; refusing (fail closed)"
[ -n "$payload" ] || refuse "the hook payload was empty; refusing (fail closed)"

# The check itself. The payload goes in on stdin, never through the
# environment: a Write of a large file would overflow ARG_MAX and turn every
# big write into a fail-closed refusal.
IFS= read -r -d '' GUARD_PY <<'PY'
import json, os, re, shlex, sys

try:
    p = json.loads(sys.stdin.read())
    tool = p.get("tool_name", "")
    ti = p.get("tool_input", {}) or {}
except Exception as exc:  # unreadable payload: refuse
    print(f"BLOCK\tpayload\tthe hook payload is not JSON ({exc}); refusing (fail closed)")
    sys.exit(0)

home = os.path.expanduser("~")
project = os.path.realpath(os.environ.get("CLAUDE_PROJECT_DIR") or os.getcwd())
# Relative paths resolve against the session's own cwd, which the payload
# carries, not against wherever the hook process happens to start.
base = p.get("cwd") or os.getcwd()

# Secret material. Globs are matched against the resolved path and against any
# word of a shell command.
SECRET_PATTERNS = [
    r"(^|/)\.env(\.(?!example$|sample$|template$|dist$)[^/\s]+)?$",
    r"\.(pem|key|p12|pfx|jks|keystore)$",
    r"(^|/)id_(rsa|dsa|ecdsa|ed25519)$",
    r"(^|/)\.ssh(/|$)",
    r"(^|/)\.aws/credentials$",
    r"(^|/)\.config/gh/hosts\.yml$",
    r"(^|/)\.fly/config\.yml$",
    r"(^|/)\.netrc$",
    r"(^|/)\.client-c-keyring(/|$)",
    r"(^|/)dev/coordinator/secrets(/|$)",
]
secret_re = [re.compile(x) for x in SECRET_PATTERNS]


def norm(path):
    path = os.path.expanduser(str(path))
    if not os.path.isabs(path):
        path = os.path.join(base, path)
    return os.path.realpath(path)


def is_secret(path):
    if not path:
        return False
    for cand in (str(path), norm(path)):
        if any(r.search(cand) for r in secret_re):
            return True
    return False


def block(rule, why):
    print(f"BLOCK\t{rule}\t{why}")
    sys.exit(0)


# ── File tools ──────────────────────────────────────────────────────────────
for key in ("file_path", "path", "notebook_path"):
    val = ti.get(key)
    if isinstance(val, str) and is_secret(val):
        block("secret-read", f"{tool} on {val} touches secret material")
if tool in ("Glob", "Grep"):
    pat = ti.get("pattern", "") if tool == "Glob" else ti.get("glob", "") or ""
    if isinstance(pat, str) and is_secret(pat):
        block("secret-read", f"{tool} for {pat} targets secret material")

if tool != "Bash":
    print("ALLOW")
    sys.exit(0)

# ── Bash ────────────────────────────────────────────────────────────────────
cmd = ti.get("command", "")
if not isinstance(cmd, str):
    block("payload", "Bash command is not a string; refusing (fail closed)")
flat = " ".join(cmd.split())

try:
    words = shlex.split(cmd, comments=False, posix=True)
except ValueError:
    words = cmd.split()

for w in words:
    for part in re.split(r"[=:,]", w):
        if part and ("/" in part or part.startswith(".")) and is_secret(part):
            block("secret-read", f"the command references secret material ({part})")
        if part and re.fullmatch(r"\.env(\.[\w-]+)?", part) and is_secret(part):
            block("secret-read", f"the command references secret material ({part})")

FLY = r"(?:fly|flyctl)"
RULES = [
    ("secrets-tool-value", r"\bsecrets-tool\s+value\b", "secrets-tool value prints a secret"),
    ("provider-secrets", rf"\b{FLY}\s+secrets\s+(set|import|unset|deploy)\b", "setting or removing Fly secrets belongs to secrets-tool deploy, run from coordinator"),
    ("provider-secrets", r"\bgh\s+secret\s+(set|delete|remove)\b", "setting or removing GitHub secrets belongs to secrets-tool deploy, run from coordinator"),
    ("provider-shell", rf"\b{FLY}\s+(ssh|console)\b", "a shell inside a running app can read every secret it holds"),
    ("provider-destroy", rf"\b{FLY}\s+(apps?\s+(destroy|delete)|destroy)\b", "destroying a Fly app"),
    ("provider-destroy", rf"\b{FLY}\s+(volumes?|vol)\s+(destroy|delete|rm)\b", "destroying a Fly volume is data loss"),
    ("provider-destroy", rf"\b{FLY}\s+(machines?|m)\s+(destroy|remove|rm)\b", "destroying a Fly machine"),
    ("provider-destroy", rf"\b{FLY}\s+(storage|postgres|pg|redis|mysql)\s+(destroy|delete)\b", "destroying provider storage is data loss"),
    ("provider-destroy", r"\bgh\s+repo\s+(delete|archive|rename)\b", "deleting, archiving or renaming a repository"),
    ("provider-destroy", r"\bgh\s+repo\s+edit\b.*--visibility\b", "changing a repository's visibility"),
    ("provider-destroy", r"\bgh\s+api\b.*(-X|--method)\s*DELETE\b", "a DELETE through the GitHub API"),
    ("history-rewrite", r"\bgit\s+(filter-repo|filter-branch)\b", "rewriting history"),
    ("pipe-to-shell", r"\b(curl|wget)\b[^|]*\|\s*(sudo\s+)?(sh|bash|zsh|dash|python3?|perl|ruby|node)\b", "piping a download into an interpreter"),
]
for rule, rx, why in RULES:
    if re.search(rx, flat):
        block(rule, why)

# git push: flags and refspecs, per push in a compound command.
for seg in re.split(r"&&|\|\||;|\|", cmd):
    try:
        sw = shlex.split(seg)
    except ValueError:
        sw = seg.split()
    if len(sw) >= 2 and sw[0] == "git":
        i = 1
        while i < len(sw) and sw[i].startswith("-"):
            i += 2 if sw[i] in ("-C", "-c") else 1
        if i < len(sw) and sw[i] == "push":
            args = sw[i + 1:]
            for a in args:
                if a in ("-f", "--force", "--mirror", "--delete", "-d", "--prune") or a.startswith("--force-with-lease") or a.startswith("--force-if-includes"):
                    block("force-push", f"git push {a} can destroy remote history")
                if re.fullmatch(r"-[a-zA-Z]*f[a-zA-Z]*", a):
                    block("force-push", f"git push {a} forces")
            pos = [a for a in args if not a.startswith("-")]
            for ref in pos[1:]:
                if ref.startswith("+"):
                    block("force-push", f"refspec {ref} forces")
                if ref.startswith(":"):
                    block("force-push", f"refspec {ref} deletes a remote branch")

# rm -r outside the worktree and temp.
allowed_roots = [project, "/tmp", "/private/tmp", "/var/folders", "/private/var/folders"]
td = os.environ.get("TMPDIR")
if td:
    allowed_roots.append(os.path.realpath(td))


def inside(path, root):
    return path == root or path.startswith(root.rstrip("/") + "/")


for seg in re.split(r"&&|\|\||;|\|", cmd):
    try:
        sw = shlex.split(seg)
    except ValueError:
        sw = seg.split()
    while sw and sw[0] in ("sudo", "command", "nice", "xargs", "env"):
        sw = sw[1:]
    if not sw or os.path.basename(sw[0]) != "rm":
        continue
    flags = [a for a in sw[1:] if a.startswith("-") and a != "--"]
    recursive = any(("r" in f.lstrip("-").lower() and not f.startswith("--")) or f in ("--recursive",) for f in flags)
    if not recursive:
        continue
    targets = [a for a in sw[1:] if not a.startswith("-")]
    for t in targets:
        if "$" in t or "`" in t:
            block("rm-outside", f"rm -r on {t}, a path that cannot be checked before it runs")
        real = norm(t)
        if real in ("/", home) or not any(inside(real, r) for r in allowed_roots):
            block("rm-outside", f"rm -r on {t} ({real}) is outside the worktree")

print("ALLOW")
PY

verdict=$(printf '%s' "$payload" | python3 -c "$GUARD_PY") \
  || refuse "the baseline check failed to run; refusing (fail closed)"

case "$verdict" in
  ALLOW) exit 0 ;;
  BLOCK*) ;;
  *) refuse "the baseline check gave no verdict; refusing (fail closed)" ;;
esac

rule=$(printf '%s' "$verdict" | cut -f2)
why=$(printf '%s' "$verdict" | cut -f3-)

# A client may lift a rule, with a recorded reason. Read only now, on the
# blocking path, so the allow path never pays for a config parse.
cfg="$(dirname "$0")/lv-config-get.sh"
if [ "$rule" != "payload" ] && [ -x "$cfg" ]; then
  if "$cfg" permissionBaseline.allow --list 2>/dev/null | grep -qx "$rule"; then
    reason=$("$cfg" permissionBaseline.reason "" 2>/dev/null)
    set_by=$("$cfg" permissionBaseline.set_by "" 2>/dev/null)
    set_on=$("$cfg" permissionBaseline.set_on "" 2>/dev/null)
    if [ -n "$reason" ] && [ -n "$set_by" ] && [ -n "$set_on" ]; then
      exit 0
    fi
    why="$why (permissionBaseline.allow lists '$rule' but reason, set_by and set_on are not all recorded, so it lifts nothing)"
  fi
fi

refuse "$rule — $why. Unattended workers may not do this. If the plan truly needs it, stop and open a gate for the operator (lv-gate-open.sh), or have the project lift '$rule' under permissionBaseline in claude-workflow.yml with a reason."
