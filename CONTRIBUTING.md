# Contributing

Feature requests are welcome; not all are accepted. The module serves one shape: a single instance with its data on an EBS volume.

- Write the `terraform test` contract test first and confirm it fails, then change the module.
- Run `pre-commit run --all-files` and check its exit status before opening a pull request.
- Run `sh scripts/docs.sh` after changing a variable, output, or provider.
- Shell scripts are POSIX `sh`: `set -eu`, a `main()` function, no `local`, no `eval`. Their tests live in `scripts/tests/`.
- Keep examples, fixtures, and tests free of account IDs, AWS profile names, personal emails, and home paths; `scripts/hygiene.sh` enforces this.
- A change to a variable, output, or resource address is a breaking change; say so in the pull request.
