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
# secrets archive, set provider secrets, destroy a volume or force-push, and the
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
# A client lifts a rule only in its own levain.yml, and only with a
# recorded reason. All four keys are required; a partial block lifts nothing:
#
#   permissionBaseline:
#     allow:
#       - provider-shell
#     reason: "deploy smoke test needs a shell on staging"
#     set_by: "A. Operator"
#     set_on: 2026-09-23
#
# Rules (the ids `allow` takes):
#   secret-read       reading secret material: .env files, private keys,
#                     credential stores, and every path the
#                     secrets-deny-patterns hook names
#   provider-secrets  gh secret set/delete, plus the provider-deny hook's
#   provider-shell    the provider-deny hook's (a shell inside a running app)
#   provider-destroy  deleting, archiving or re-publishing a GitHub repo, plus
#                     the provider-deny hook's (apps, volumes, storage)
#   (a hook's own)    a pack may name further ids, e.g. a secrets tool's
#                     print-a-value command
#   force-push        git push --force/-f/--force-with-lease/--mirror/--delete,
#                     or a +refspec or :branch refspec
#   history-rewrite   git filter-repo, git filter-branch
#   rm-outside        rm -r on a path outside the worktree and temp dirs
#   pipe-to-shell     curl or wget piped into a shell or interpreter
#
# This is a guard against a mistaken or misled agent, not a sandbox against a
# hostile one. Rules match where a command starts (LVI-036), so prose naming a
# command in a quoted argument is not refused. A command assembled at run time
# (base64, variables) can still get past it. Deny rules and the provider's own scoping remain the
# deeper layers.
#
# THE HOOKS (LVI-013)
#
# Your secrets tool and hosting provider are not the library's to know. Their
# rules come from two add-deny hooks, secrets-deny-patterns and provider-deny
# (lv-hook.sh; the format is in hooks.default/secrets-deny-patterns), usually
# from a private pack. They can only add rules. If either fails — a listed
# pack that has gone, a hook that errors — the worker is refused everything,
# because a pack that moved must not quietly take its guards with it.
#
# Exit 0 allow, 2 block.

set -uo pipefail

[ "${LV_UNATTENDED:-}" = "1" ] || exit 0

refuse() { printf 'permission baseline: %s\n' "$1" >&2; exit 2; }

command -v python3 >/dev/null 2>&1 || refuse "python3 is missing, so the call cannot be checked; refusing (fail closed)"

payload=$(cat 2>/dev/null) || refuse "the hook payload could not be read; refusing (fail closed)"
[ -n "$payload" ] || refuse "the hook payload was empty; refusing (fail closed)"

# The rules the owner's packs add. Handed over in the environment: they are a
# few lines, unlike the payload.
hook="$(dirname "$0")/lv-hook.sh"
[ -x "$hook" ] || refuse "lv-hook.sh is missing, so the pack rules cannot be read; refusing (fail closed)"
extra=$("$hook" secrets-deny-patterns </dev/null) \
  || refuse "the secrets-deny-patterns hook failed; refusing (fail closed)"
extra="$extra"$'\n'$("$hook" provider-deny </dev/null) \
  || refuse "the provider-deny hook failed; refusing (fail closed)"
export LV_BASELINE_EXTRA="$extra"

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
    r"(^|/)\.netrc$",
]
RULES = [
    ("provider-secrets", r"\bgh\s+secret\s+(set|delete|remove)\b", "setting or removing GitHub secrets belongs to the secrets-deploy hook, not to a worker"),
    ("provider-destroy", r"\bgh\s+repo\s+(delete|archive|rename)\b", "deleting, archiving or renaming a repository"),
    ("provider-destroy", r"\bgh\s+repo\s+edit\b.*--visibility\b", "changing a repository's visibility"),
    ("provider-destroy", r"\bgh\s+api\b.*(-X|--method)\s*DELETE\b", "a DELETE through the GitHub API"),
    ("history-rewrite", r"\bgit\s+(filter-repo|filter-branch)\b", "rewriting history"),
]

# Piping a download into an interpreter spans two commands, so it is checked
# on the pipeline below, not as a rule; this is the fallback for text the
# lexer cannot follow.
PIPE_TO_SHELL = r"\b(curl|wget)\b[^|]*\|\s*(sudo\s+)?(sh|bash|zsh|dash|python3?|perl|ruby|node)\b"

# What the secrets-deny-patterns and provider-deny hooks added (see the shell
# above). A line this cannot use refuses: a pack's rule that silently fails to
# load is a guard that is not there.
for line in os.environ.get("LV_BASELINE_EXTRA", "").splitlines():
    if not line.strip():
        continue
    f = line.split("\t")
    try:
        if f[0] == "path" and len(f) == 2 and f[1].strip():
            sp = f[1].strip()
            rel = (sp[2:] if sp.startswith("~/") else sp.lstrip("/")).rstrip("/")
            SECRET_PATTERNS.append(r"(^|/)" + re.escape(rel) + r"(/|$)")
        elif f[0] == "command" and len(f) == 4 and re.fullmatch(r"[a-z][a-z0-9-]*", f[1]):
            re.compile(f[2])
            RULES.append((f[1], f[2], f[3]))
        else:
            raise ValueError("not a path or command line")
    except Exception as exc:
        print(f"BLOCK\tpayload\ta pack rule could not be read ({line[:80]!r}: {exc}); refusing (fail closed)")
        sys.exit(0)
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

# A heredoc's body is data when what reads it only stores or displays it.
# `cat >> plan.md <<'EOF'` whose prose named a secrets tool's print command was
# refused as though it ran it (a client's LVI-004), and the worker had to fall
# back to the Edit tool. So the body is dropped before matching, but only
# when the reader is on this short list of data sinks and nothing on the
# opening line pipes onward. A body a shell reads stays in the command, where
# its lines are commands like any other; a body anything else reads (python,
# node, ...) is code of another language and is checked as plain text.
DATA_SINKS = {"cat", "tee", "git", "gh", "wc", "grep", "head", "tail", "sort"}
SHELLS = {"sh", "bash", "zsh", "dash", "ksh", "ssh"}
HEREDOC = re.compile(r"<<(-?)[ \t]*(['\"]?)\\?([A-Za-z_][A-Za-z0-9_]*)\2")


def strip_heredocs(text):
    lines = text.split("\n")
    out, text_bodies, i = [], [], 0
    while i < len(lines):
        line = lines[i]
        out.append(line)
        i += 1
        m = HEREDOC.search(line)
        if not m:
            continue
        before = re.split(r"\$\(|\(|;|&&|\|\|", line[:m.start()])[-1]
        piped = line[m.end():].split("|", 1)
        reader = piped[1] if len(piped) > 1 else before.split("|")[-1]
        try:
            rw = [w for w in shlex.split(reader) if w not in ("sudo", "env", "command")]
            first = os.path.basename(rw[0]) if rw else ""
        except ValueError:
            first = ""
        kind = "data" if first in DATA_SINKS and len(piped) == 1 else "shell" if first in SHELLS else "text"
        dash, delim = m.group(1), m.group(3)
        body = []
        while i < len(lines):
            b = lines[i]
            i += 1
            if (b.lstrip("\t") if dash else b) == delim:
                out.append(b)
                break
            body.append(b)
        if kind == "shell":
            out.extend(body)
        elif kind == "text":
            text_bodies.append("\n".join(body))
    return "\n".join(out), text_bodies


# A rule names a command, so it is matched where a command starts, not
# anywhere in the text: a worker filing an issue whose quoted --actual named a
# secrets tool's print command, and a test asserting a runbook lacks it, were
# both refused as though they ran it (a client's LVI-036). lex() splits shell
# text into simple commands and pulls out every $(...) and `...` it meets
# outside single quotes, which run and are checked in turn.
class Unparsed(ValueError):
    pass


def close_paren(s, i):
    """Index of the ')' closing the '(' at s[i]; quotes inside are skipped."""
    depth, q = 0, None
    while i < len(s):
        c = s[i]
        if q:
            if c == "\\" and q == '"':
                i += 1
            elif c == q:
                q = None
        elif c in "'\"":
            q = c
        elif c == "\\":
            i += 1
        elif c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
            if depth == 0:
                return i
        i += 1
    raise Unparsed("unclosed $(")


def close_tick(s, i):
    j = i + 1
    while j < len(s):
        if s[j] == "\\":
            j += 2
            continue
        if s[j] == "`":
            return j
        j += 1
    raise Unparsed("unclosed backtick")


def lex(s):
    """([[word, ...], ...], [(command index, separator before it)], [substitution text])"""
    cmds, seps, subs = [[]], ["start"], []
    word, i, n = None, 0, len(s)

    def end_word():
        nonlocal word
        if word is not None:
            cmds[-1].append(word)
            word = None

    def new_cmd(sep):
        end_word()
        if cmds[-1]:
            cmds.append([])
            seps.append(sep)
        else:
            seps[-1] = sep if seps[-1] == "start" else seps[-1]

    while i < n:
        c = s[i]
        if c == "\\":
            if s[i + 1:i + 2] != "\n":
                word = (word or "") + s[i + 1:i + 2]
            i += 2
        elif c == "'":
            j = s.find("'", i + 1)
            if j < 0:
                raise Unparsed("unclosed '")
            word = (word or "") + s[i + 1:j]
            i = j + 1
        elif c == '"':
            i += 1
            buf = ""
            while i < n and s[i] != '"':
                if s[i] == "\\" and i + 1 < n:
                    buf += s[i + 1] if s[i + 1] in '"\\$`' else s[i:i + 2]
                    i += 2
                elif s.startswith("$(", i):
                    j = close_paren(s, i + 1)
                    subs.append(s[i + 2:j])
                    buf += s[i:j + 1]
                    i = j + 1
                elif s[i] == "`":
                    j = close_tick(s, i)
                    subs.append(s[i + 1:j])
                    buf += s[i:j + 1]
                    i = j + 1
                else:
                    buf += s[i]
                    i += 1
            if i >= n:
                raise Unparsed('unclosed "')
            word = (word or "") + buf
            i += 1
        elif s.startswith("$(", i):
            j = close_paren(s, i + 1)
            subs.append(s[i + 2:j])
            word = (word or "") + s[i:j + 1]
            i = j + 1
        elif c == "`":
            j = close_tick(s, i)
            subs.append(s[i + 1:j])
            word = (word or "") + s[i:j + 1]
            i = j + 1
        elif c in " \t":
            end_word()
            i += 1
        elif c == "|" and s[i + 1:i + 2] != "|":
            new_cmd("|")
            i += 1
        elif c in "\n;&|(){}":
            new_cmd(";")
            i += 1
        elif c in "<>":
            end_word()
            i += 1
        elif c == "#" and word is None:
            while i < n and s[i] != "\n":
                i += 1
        else:
            word = (word or "") + c
            i += 1
    end_word()
    return cmds, seps, subs


# Words that run the rest of their line as a command.
PREFIXES = {"sudo", "env", "command", "builtin", "exec", "nice", "nohup", "time", "timeout", "xargs", "stdbuf", "watch"}
# Commands that run a string argument as shell text.
STRING_RUNNERS = {"sh", "bash", "zsh", "dash", "ksh", "eval", "ssh", "su"}


def head(words):
    """The words from the command name on: assignments and wrappers dropped."""
    k = 0
    while k < len(words):
        w = words[k]
        if re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*=.*", w, re.S):
            k += 1
        elif os.path.basename(w) in PREFIXES:
            k += 1
            while k < len(words) and (words[k].startswith("-") or re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*=.*|[\d.]+[smhd]?", words[k], re.S)):
                k += 1
        else:
            break
    return words[k:]


def commands(text, depth=0):
    """Each simple command in text, as its words from the command name on."""
    if depth > 4:
        raise Unparsed("nested too deep")
    cmds, seps, subs = lex(text)
    found = []
    for sub in subs:
        found += commands(sub, depth + 1)
    for idx, words in enumerate(cmds):
        h = head(words)
        if not h:
            continue
        name = os.path.basename(h[0])
        found.append(([name] + h[1:], seps[idx]))
        # A command name with spaces in it is a quoted script; a shell, eval or
        # ssh runs its string arguments.
        if re.search(r"\s", h[0]):
            found += commands(h[0], depth + 1)
        if name in STRING_RUNNERS:
            for w in h[1:]:
                if re.search(r"\s", w):
                    found += commands(w, depth + 1)
            found += commands(" ".join(h[1:]), depth + 1)
    return found


INTERPRETERS = {"sh", "bash", "zsh", "dash", "python", "python3", "perl", "ruby", "node"}

cmd, text_bodies = strip_heredocs(cmd)
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

for body in text_bodies:
    body_flat = " ".join(body.split())
    for rule, rx, why in RULES:
        if re.search(rx, body_flat):
            block(rule, why)

try:
    simple = commands(cmd)
except Unparsed:
    simple = None

if simple is None:
    # Text the lexer cannot follow is matched anywhere, as before LVI-036:
    # a guard that cannot read a command refuses rather than guesses.
    for rule, rx, why in RULES:
        if re.search(rx, flat):
            block(rule, why)
    if re.search(PIPE_TO_SHELL, flat):
        block("pipe-to-shell", "piping a download into an interpreter")
else:
    for rule, rx, why in RULES:
        crx = re.compile(rx)
        for words_, _ in simple:
            if crx.match(" ".join(words_)):
                block(rule, why)
    fetched = False
    for words_, sep in simple:
        if sep != "|":
            fetched = False
        if words_[0] in ("curl", "wget"):
            fetched = True
        elif fetched and sep == "|" and words_[0] in INTERPRETERS:
            block("pipe-to-shell", "piping a download into an interpreter")

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

refuse "$rule — $why. Unattended workers may not do this. If the plan truly needs it, stop and open a gate for the operator (lv-gate-open.sh), or have the project lift '$rule' under permissionBaseline in levain.yml with a reason."
