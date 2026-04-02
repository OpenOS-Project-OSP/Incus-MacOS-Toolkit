# Contributing

This project consolidates multiple upstream repositories. See CREDITS.md for
the full list of upstreams.

## Development setup

1. Fork this repository
2. Create a feature branch: `git checkout -b my-feature`
3. Make changes and commit
4. Open a pull request against `main`

## Code style

- Shell scripts: follow existing style, pass `shellcheck`
- Python: `ruff check` clean
- Go: `gofmt` formatted, `go vet` clean
- C: `clang-format` with the project's `.clang-format`

## License

All contributions are licensed under GPL-3.0-or-later.
