# CLAUDE.md

For project conventions, build commands, architecture, gotchas, and
contribution guidelines, see [AGENTS.md](AGENTS.md). Everything below is
specific to the Claude Code operator experience on this repo.

## Commit Signing

The SessionStart hook configures repo-local signing automatically each
session using Claude's dedicated key (see `~/.claude/CLAUDE.md` for
identity details). Verify signing is active before your first commit:

```bash
git config commit.gpgsign   # should return true
```

If signing fails, set it up manually:

```bash
git config --local user.name "Claude Code (nugget)"
git config --local user.email "claude@nugget.info"
git config --local user.signingkey "~/.claude/ssh/id_claude"
git config --local gpg.format ssh
git config --local commit.gpgsign true
git config --local gpg.ssh.allowedsignersfile "~/.claude/ssh/allowed_signers"
git config --local gpg.ssh.program ssh-keygen
```

## CI Gate

**MANDATORY: `just ci` must pass locally before every `git push`. No
exceptions.** Do not rely on GitHub Actions — run the full gate locally
first and fix any issues before pushing. CI is a safety net, not the
first line of defense.

## Release Engineering

Releases require `THANE_CODESIGN_IDENTITY` and `THANE_NOTARY_PROFILE`
in the environment. The user typically sets these in their fish shell,
so Claude's bash subshells won't inherit them. Two options:

1. Ask the user to run `just release VERSION` from their own shell.
2. Ask them to drop the vars into `.env` (gitignored) so just's
   `set dotenv-load` can pick them up.

Never push directly to `main` — `just release` gates on `HEAD` matching
`origin/main`, so release commits must be merged via PR first.

## GitHub Collaboration

Be a good GitHub collaborator. Review threads left open signal
unfinished work — always close the loop.

**When addressing review feedback:**

1. Fix the issue in a commit
2. Reply to the thread with the fixing commit hash and a one-line
   explanation
3. Resolve the conversation
4. If deferring (out of scope, follow-up issue), say so explicitly
   before resolving

**After a round of fixes:** Request re-review so the reviewer knows
the ball is back in their court.

**Resolving threads via CLI:**

```bash
gh api graphql -f query='mutation { resolveReviewThread(input: {threadId: "THREAD_ID"}) { thread { isResolved } } }'
```

**PR hygiene:**

- Check off test plan items as they are verified
- Use `Refs #NNN` or `Closes #NNN` in commit bodies
- Keep the PR description accurate as scope evolves
