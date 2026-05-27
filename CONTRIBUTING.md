# Contributing

Thanks for helping improve gengo.

## Development Flow

- Keep changes focused and small.
- Add or update examples/spec cases for behavior changes.
- Prefer explicit runtime errors over implicit behavior.

## Local Validation

Run these before opening a PR:

```bash
make wasi
make test
```

If relevant, also run:

```bash
make bench
make parity
```

## Pull Requests

- Describe what changed and why.
- Mention user-visible behavior changes.
- Include any new/updated spec cases.
