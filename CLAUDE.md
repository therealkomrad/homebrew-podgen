# Podgen — Claude Code Instructions

Ruby 3.2+, macOS. Two pipelines (news, language) + Tell CLI/web. See README.md and ARCHITECTURE.md for details.

## Non-negotiable

1. **Bug or feature request → respond with a plan, NOT a code edit.** Read the relevant code first. For bugs: list multiple hypotheses, gather evidence, present diagnosis. For features: describe approach, files you'll touch, tests you'll add. Wait for explicit "yes" before editing.
2. **Failing test before fix.** Regression test for bugs, behavior spec for features. Confirm it fails for the *right* reason before writing the implementation.
3. **No drive-by changes.** Do only what was asked. Refactors are separate commits with separate approval.
4. **Push to master / ship / release → run CRPR.** See workflow below. Skip ONLY if user said "CPR" or "skip review."
5. **Pre-existing failing tests are bug signals.** Flag them. Never skip, dismiss, or treat as background noise.

## Conventions

- Tests: Minitest. `rake test:unit` (fast), `rake test` (all). Single file: `bundle exec ruby -Ilib:test test/unit/<file>.rb`.
- Test naming: `test_<method>_<scenario>_<outcome>`. Structure: Arrange → Act → Assert.
- Test tiers: `test/unit/` (no I/O), `test/integration/`, `test/api/` (gated by `skip_unless_env`).
- HTTP retries: `HttpRetryable#with_http_retries`. API retries: `Retryable#with_retries`.
- Shell: `Open3.capture3`. Paths: `File.join` + `__dir__`-relative. `require_relative` everywhere.
- API keys from ENV only. Atomic writes (temp + rename) for history/cache. Gems pinned `~> x.y`.
- TTS split order: paragraph → sentence → comma → whitespace → UTF-8 char boundary.
- Single responsibility per class/method.

## CRPR — default workflow for push to master / release

1. Commit.
2. **Review** — spawn worktree agent (`isolation: "worktree"`) running `/cr` skill. Read-only; no shared context.
3. **Resolve** — fix all BLOCKERs and WARNINGs. Re-commit, re-review until APPROVED or APPROVED WITH WARNINGS. NITs optional.
4. On APPROVED, mark HEAD as reviewed: `git update-ref refs/cr/reviewed HEAD`. The release guard hook reads this ref to unblock push. (The old `.claude/last-review.sha` file is still honored as a fallback for backward compatibility but the ref is the canonical mechanism.)
5. `git push` to origin (CI runs unit tests).
6. Verify CI green via `gh run list`. If red, diagnose, fix, recommit, retry.
7. `gh release create` (Homebrew formula auto-updates via `.github/workflows/homebrew.yml`).

"CPR" = skip steps 2–4. The hook will detect "CPR" / "skip review" in the prompt and let the push through once.

## Workflow notes

- Screenshots/pics: check `~/Desktop` for recent .png files sorted by date.
- "Document" = update CLAUDE.md and README.md.
