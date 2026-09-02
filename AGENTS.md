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
directories. Document any intentional deviation from this layout in `README.md`.

## Build, Test, and Development Commands

No language runtime, package manager, or build tooling is configured yet. Add
the canonical commands to `README.md` when the project is initialized, and keep
them scriptable and non-interactive. For example, a JavaScript project should
provide `npm run dev`, `npm test`, and `npm run lint`; a Python project should
document the equivalent `pytest` and formatter commands. Run the available
formatter, linter, and test suite before requesting review.

## Coding Style & Naming Conventions

Follow the formatter and linter configured for the chosen language; do not
hand-format around their output. Use two spaces for JSON, YAML, and Markdown
nested lists unless a tool dictates otherwise. Prefer descriptive names:
`user-profile.ts`, `parse_config`, and `UserProfile`. Keep modules focused,
avoid unexplained abbreviations, and add comments only for non-obvious intent.

## Testing Guidelines

Add tests with every behavior change. Name test files after the module under
test (for example, `tests/user-profile.test.ts`) and write test descriptions
that state the expected behavior. Cover normal behavior, boundary cases, and
regressions before merging.

## Commit & Pull Request Guidelines

No existing commit history establishes a convention. Use short, imperative
subjects such as `Add configuration parser` or `Fix empty input handling`.
Keep commits focused. Pull requests should summarize the change, explain how it
was verified, link relevant issues, and include screenshots for visible UI
changes. Flag configuration, migration, or security implications explicitly.
