# Contributing

Strip is experimental and maintained on a best-effort basis. Focused bug fixes, tests,
documentation, and measured performance work are welcome.

## Prerequisites

- macOS 14 or newer
- Xcode 16 command-line tools
- Accessibility permission for live testing
- Screen Recording permission for thumbnail or visual verification work

## Development Workflow

```bash
make test
make bundle
make open
```

Use `make open` for live behavior. `make run` is not a valid Accessibility-trusted launch path.
`make setup-signing` is optional, local, reversible, and development-only; read
[docs/DEVELOPMENT_SIGNING.md](docs/DEVELOPMENT_SIGNING.md) first.

## Pull Requests

- Keep changes focused and preserve Swift language mode v5.
- Put layout decisions in pure `StripKit` logic where they can be unit tested.
- Add or update tests for behavior changes and run `make ci`.
- Do not commit builds, traces, private screenshots, logs, credentials, or agent session context.
- Update public docs when permissions, private APIs, installation, or support scope change.

## Performance Changes

Performance changes require a measured baseline, an equivalent before/after workload, tail-latency
results, and visual verification when rendering changes. Read [MEASURING.md](MEASURING.md) first.

## End-to-End Tests

`make e2e` controls the real desktop and requires a clean environment. Prefer `make e2e-vm` for
repeatable isolation. See [TESTING.md](TESTING.md).

## Security

Do not open public issues for vulnerabilities involving permissions, window contents, signing, or
control of other applications. Follow [SECURITY.md](SECURITY.md).
