# Contributing to DepotKit

Thank you for your interest in contributing to DepotKit! This document explains how to get started.

## Developer Certificate of Origin (DCO)

All contributions require a [Developer Certificate of Origin](https://developercertificate.org/) sign-off. This certifies that you wrote the contribution or have the right to submit it under the project's license.

Add a `Signed-off-by` line to every commit:

```
feat: add support for custom coders

Signed-off-by: Jane Doe <jane.doe@example.com>
```

Git can do this automatically with the `-s` flag:

```bash
git commit -s -m "feat: add support for custom coders"
```

The [DCO GitHub bot](https://github.com/apps/dco) checks all pull requests. Commits without a sign-off will fail the check.

## Getting Started

1. Fork the repository
2. Clone your fork and create a feature branch from `main`
3. Run `scripts/setup.sh` to install the pre-commit hook
4. Make your changes
5. Run tests (`swift test`)
6. Push your branch and open a pull request

## Development Setup

DepotKit requires **Swift 6.2** (Xcode 26+) and has no external runtime dependencies. Formatting is handled by `swift-format`, which ships with Xcode.

```bash
# Install the pre-commit hook (one-time)
scripts/setup.sh

# Build
swift build

# Run all tests
swift test

# Format code
scripts/format.sh

# Check formatting without modifying files
scripts/format.sh --check

# Check / fix license headers
scripts/check-license-headers.sh
scripts/check-license-headers.sh --fix
```

## Pull Request Guidelines

- Keep PRs focused — one feature or fix per PR.
- Sign all commits (`git commit -s`). The DCO bot enforces this.
- Run `scripts/format.sh` before submitting. The pre-commit hook checks this automatically.
- Add tests for new functionality. Test coverage should not decrease.
- Update documentation if your change affects public API.
- Every new `.swift` file must include the SPDX license header — run `scripts/check-license-headers.sh --fix` to add it.
- Use clear, descriptive commit messages following the format below.

## Commit Messages

```
type: short summary

Optional longer description explaining the "why" behind the change.

Signed-off-by: Your Name <your.email@example.com>
```

Where `type` is one of: `feat`, `fix`, `refactor`, `test`, `docs`, `chore`.

## Reporting Issues

- Use [GitHub Issues](https://github.com/mercedes-benz/DepotKit/issues) for bug reports and feature requests.
- Include reproduction steps, expected vs. actual behavior, and your environment (Swift version, OS, Xcode version).

## Code of Conduct

This project follows the [Mercedes-Benz Open Source Code of Conduct](CODE_OF_CONDUCT.md). Please read it before participating.
