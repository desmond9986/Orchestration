# Changelog

All notable changes to this project will be documented in this file.

The format is based on Keep a Changelog, and this project follows Semantic Versioning.

## [Unreleased]
### Added
- `orch-preflight` command to validate local dependencies, roster integrity, and bypass-env safety before orchestration runs.
- `orch-preflight --repair` to recreate required `.agents` task files and repair stale roster pane targets from tmux `@orch_agent_id` metadata.
- `ui-ux-designer` core role and hat for design-spec-first UI workflows; integrates with the `huashu-design` skill for HTML prototype generation.
- GitHub CI workflow (shell lint, syntax check, smoke tests).
- Issue templates and pull request template.
- Open-source baseline files: `NOTICE`, `.env.example`, `VERSION`.

### Changed
- `orchestrate` now clears inherited `ORCH_SKIP_PERMISSIONS*` by default unless bypass was explicitly requested or `--respect-env-skip-permissions` is set.
- Codex permission bypass now uses the current CLI flag: `--dangerously-bypass-approvals-and-sandbox --no-alt-screen`.

## [0.1.0] - 2026-04-20
### Added
- Initial public release baseline.
