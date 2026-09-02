# Repository Guidelines

## Project Structure & Module Organization

This repository is currently an empty scaffold. Keep the root limited to project
configuration and top-level documentation. As code is introduced, use a clear
and conventional layout:

- `src/` for production source code, organized by feature or module.
- `tests/` for automated tests, mirroring paths beneath `src/` where practical.
- `assets/` for static, non-generated resources such as images or fixtures.
- `docs/` for design notes, setup instructions, and architecture decisions.

Avoid committing generated output, local caches, credentials, or dependency
directories. Document any intentional deviation in `Plan.md` or `docs/`.

## Build, Test, and Development Commands

No language runtime, package manager, or build tooling is configured yet. Add
the canonical commands to this guide or `Plan.md` when the project is
initialized, and keep them scriptable and non-interactive. For example, a JavaScript project should
provide `npm run dev`, `npm test`, and `npm run lint`; a Python project should
document the equivalent `pytest` and formatter commands. Run the available
formatter, linter, and test suite before requesting review.

## Definition of Done

A change is complete when:

1. The requested behavior is implemented.
2. Relevant tests exist and pass.
3. Lint, type, and build checks pass where applicable.
4. Required GitHub CI checks pass.
5. The final diff contains no unrelated changes.
6. No known regression or security issue was introduced.
7. Any remaining limitation is explicitly reported.

## Coding Style & Naming Conventions

Follow the formatter and linter configured for the chosen language; do not
hand-format around their output. Use two spaces for JSON, YAML, and Markdown
nested lists unless a tool dictates otherwise. Prefer descriptive names:
`user-profile.ts`, `parse_config`, and `UserProfile`. Keep modules focused,
avoid unexplained abbreviations, and add comments only for non-obvious intent.

## Testing Guidelines

- Run the smallest relevant test suite while developing.
- Before completion, run all tests reasonably affected by the change.
- Never delete, disable, skip, or weaken an existing test just to make CI pass.
- If an existing test appears incorrect, explain why before modifying it.
- Add a regression test for bug fixes whenever practical.
- Test expected behavior, important edge cases, and relevant failures.
- Keep tests deterministic; avoid arbitrary sleeps, timing assumptions, and network dependencies where possible.

## Commit & Pull Request Guidelines

- Keep commits focused on one logical change with short, imperative subjects such as `Add configuration parser`.
- Keep pull requests narrowly scoped. Before opening or updating one, inspect the diff, remove accidental changes, and run relevant checks.
- PR descriptions should summarize what changed, why, important implementation decisions, tests performed, and known limitations or follow-up work.
- Link relevant issues and include screenshots for visible UI changes.
- Never hide failing tests or unresolved issues; address review comments by fixing the underlying issue.

## CI and GitHub Actions

- Treat required CI checks as part of the definition of done; never claim completion while required checks fail.
- If CI fails, determine whether the current change caused it, fix failures caused by the change, and report unrelated failures separately.
- Reproduce CI commands locally whenever practical before pushing another fix.
- Prefer existing workflows over duplicate workflows. Pin or constrain third-party actions and keep permissions as restrictive as practical.
- Never expose secrets in logs or workflow YAML, and do not reduce linting, type-checking, coverage, or compiler strictness without an explicit reason.

## Issues

- Do not close an issue merely because code was written.
- Verify acceptance criteria before resolving an issue.
- Reference relevant issues from commits or PRs when appropriate.
- Document additional out-of-scope work instead of silently expanding the task.

## Dependencies

- Do not add a dependency if the existing stack can reasonably solve the problem.
- Before adding one, consider maintenance status, license, bundle/runtime impact, security implications, and necessity.
- Do not perform broad dependency upgrades as part of an unrelated change.

## Repository Safety

- Never commit API keys, tokens, passwords, certificates, `.env` contents, build artifacts, or local secrets.
- Do not use force-push, destructive resets, or history rewriting unless explicitly requested.
- Do not alter branch protection, required checks, repository permissions, or GitHub secrets unless explicitly requested.
- Do not merge a PR unless explicitly authorized or bypass required reviews.
