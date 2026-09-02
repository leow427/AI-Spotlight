# AI Spotlight

AI Spotlight is a planned, local-first, keyboard-driven AI chat app for macOS.
See [Plan.md](Plan.md) for the prototype architecture and implementation steps.

## Definition of Done

A change is complete when:

1. The requested behavior is implemented.
2. Relevant tests exist and pass.
3. Lint/type/build checks pass where applicable.
4. Required GitHub CI checks pass.
5. The final diff contains no unrelated changes.
6. No known regression or security issue was introduced.
7. Any remaining limitation is explicitly reported.

## Testing

- Run the smallest relevant test suite while developing.
- Before considering a task complete, run all tests reasonably affected by the change.
- Never delete, disable, skip, or weaken an existing test just to make CI pass.
- If an existing test appears incorrect, explain why before modifying it.
- Bug fixes should include a regression test whenever practical.
- New behavior should have tests for expected behavior, important edge cases, and relevant failure/error conditions.
- Do not rewrite unrelated tests.
- Tests must be deterministic; avoid arbitrary sleeps, timing assumptions, and network dependencies where possible.

## CI

- Treat required CI checks as part of the definition of done.
- Never claim a task is complete while required CI is failing.
- If CI fails, determine whether the current change caused it, fix failures caused by the change, and report unrelated or pre-existing failures separately.
- Do not modify CI configuration merely to bypass a failing check.
- Do not reduce linting, type-checking, coverage, or compiler strictness without an explicit reason.
- Reproduce CI commands locally whenever practical before pushing another fix.

## Git

- Keep commits focused on one logical change.
- Do not commit generated files, build artifacts, secrets, credentials, or local configuration unless the repository explicitly tracks them.
- Do not use `git push --force`, destructive resets, or history rewriting unless explicitly requested.
- Do not modify unrelated files merely because formatting or tooling detected them.
- Preserve existing repository conventions.

## Pull Requests

- Keep PRs narrowly scoped.
- Before opening or updating a PR, inspect the diff, remove accidental changes, and run the relevant tests and required lint/type/build checks.
- PR descriptions should summarize what changed, why, important implementation decisions, tests performed, and known limitations or follow-up work.
- Never hide failing tests or unresolved issues in the PR description.
- Address review comments by fixing the underlying issue rather than making superficial changes solely to satisfy the comment.

## GitHub Actions

- Prefer existing workflows over creating duplicate workflows.
- Pin or constrain third-party actions appropriately.
- Never expose secrets in logs.
- Do not add secrets directly to workflow YAML.
- Keep workflow permissions as restrictive as practical.
- Avoid granting `write` permissions when `read` is sufficient.
- Treat changes to deployment or release workflows as higher-risk than ordinary code changes.

## Issues

- Do not close an issue merely because code was written.
- Verify the acceptance criteria before considering an issue resolved.
- Reference the relevant issue from commits or PRs when appropriate.
- If implementation reveals additional work outside scope, document it rather than silently expanding the task.

## Dependencies

- Do not add a dependency if the existing stack can reasonably solve the problem.
- Before adding one, consider its maintenance status, license, bundle/runtime impact, security implications, and whether it is actually necessary.
- Do not perform broad dependency upgrades as part of an unrelated feature or bug fix.

## Repository Safety

- Never commit API keys, tokens, passwords, certificates, `.env` contents, or other secrets.
- Do not alter branch protection, required checks, repository permissions, secrets, or GitHub settings unless explicitly requested.
- Do not merge a PR unless explicitly authorized.
- Do not bypass branch protection or required reviews.
