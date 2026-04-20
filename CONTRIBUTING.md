# Contributing

Thanks for your interest in improving orchestration.

## Ground rules

- Keep changes focused and minimal.
- Prefer safety and determinism over cleverness.
- Do not commit secrets, tokens, local credentials, or private logs.
- Add or update tests for behavior changes when practical.

## Development flow

1. Fork and create a branch.
2. Make changes with clear commit messages.
3. Run smoke tests:

```bash
tests/smoke.sh all
```

4. Open a pull request with:
- Problem statement
- Proposed change
- Risk and rollback notes
- Test evidence

## PR expectations

- Backward compatibility should be called out explicitly.
- New CLI flags/options must be documented in `README.md`.
- Breaking changes require migration notes.

## Report issues

For bugs/feature requests, open a GitHub issue with reproduction steps and expected vs actual behavior.

For security issues, do **not** open a public issue. See `SECURITY.md`.
