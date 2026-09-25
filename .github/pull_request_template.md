<!--
This pull request will be read line by line, applied to the private library as a patch with
your authorship kept, and closed with a comment naming the version that carries it. It is not
merged here: the public history is rebuilt on every publish. See CONTRIBUTING.md.

It is public. Check the diff first:
  git format-patch --stdout origin/main..HEAD | ./check-denylist.sh --outbound --text -
-->

**Fixes:** <!-- #issue, or the fault in one line -->

**Levain version it was found on:**

**What was wrong:**

**What the fix does:**

**The test that fails without it:** <!-- tests/<file>.sh — the assertion's name -->

- [ ] One fault only
- [ ] `for t in tests/*.sh; do bash "$t" || echo "FAILED: $t"; done` passes
- [ ] A changed `SKILL.md` still meets docs/prompt-contract.md
- [ ] `check-denylist.sh --outbound` on the diff exits 0
