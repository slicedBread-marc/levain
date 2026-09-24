# Preflight

> Part of [START.md](../START.md). Runs first, every time. It is read-only unless the platform
> needs adapting, and then it asks before changing anything.

## Check

Run these and collect the results. Do not stop at the first failure.

| Check | Command | Needed |
|-|-|-|
| Platform | `uname -s` | Levain is built and tested on **macOS** (`Darwin`) |
| Bash | `bash --version` | 3.2 or later. macOS's own 3.2 is fine, and nothing needs a newer one |
| Git | `git --version` | Required. The project must be a git repository (`git rev-parse --show-toplevel`) |
| Python | `python3 --version` | Required. Settings merges and a few parsers use it |
| Claude Code | `claude --version` | Required. The daemon's workers are `claude -p` sessions |
| yq | `command -v yq` | Recommended. Lets verification run only the tests a plan touches. Without it, set `LV_TEST_SCOPE_FALLBACK=full` and every run uses the whole suite |
| jq | `command -v jq` | Optional. The cross-project board reads worker details with it |
| Node + npm | `command -v node npm` | Optional. Only for headless browser checks of web UIs |

Report the results as a short table. If something required is missing, name the usual install
(for example `brew install yq`) and ask before installing anything. Do not go on to the next
prompt while a required check fails.

## Off macOS

Say it once, plainly: *Levain is built and tested on macOS. On this platform I can adapt the
scripts in place. There is no further promise than that.* Then, if they want to go on:

1. Work in the **library** (`$LIB`), on a local branch: `git -C "$LIB" switch -c local/platform`.
   Clients get copies at install time, so the fix belongs where the copies come from.
2. Find the BSD-only forms and make each one portable. Do not just swap it for the GNU form:
   - `sed -i ''` → a form that works on both systems, such as writing to a temp file and then `mv`
   - `stat -f` → a small `case "$(uname -s)"` that uses `stat -c` on Linux
   - `date -j`, `date -v` → the equivalent `date -d`, behind the same kind of `case`

   `grep -rnE "sed -i ''|stat -f|date -[jv]" "$LIB/scripts" "$LIB/install.sh" "$LIB/deploy-all.sh"`
   finds the known ones. The test suite (`for t in "$LIB"/tests/*.sh; do bash "$t"; done`)
   finds the ones that grep misses.
3. Commit on that branch and report every file you changed. `install/upgrade.md` rebases this
   branch onto each new version, so the adaptation carries forward.
