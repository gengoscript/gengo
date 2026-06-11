# Gengoscript Site Builder

A minimal static site generator written in Gengoscript, built to eat our own dog food.

## Usage

From the repository root:

```bash
# Build the native CLI
zig build -Dpreset=dev cli

# Run the site builder (requires cap:fs)
./zig-out/bin/gengo --cap fs --mount root=. tools/site-builder/site-builder.gengo
```

This reads `.md` files from `docs/` and writes HTML to `build/site/`.
Paths are mount-based (`root/` maps to the repository root).

## What it does

- Lists all `.md` files in `docs/`
- Converts basic Markdown to HTML:
  - Headers (`#`, `##`, `###`)
  - Paragraphs
  - Code blocks (```)
  - Inline code (`)
  - Bold (`**`), italic (`*` or `_`)
  - Links (`[text](url)`)
  - Images (`![alt](url)`)
  - Unordered lists (`- ` or `* `)
  - Blockquotes (`> `)
  - Horizontal rules (`---`)
- Extracts page title from the first H1
- Generates an index page with navigation
- Links a simple CSS stylesheet

## Limitations

- No tables, footnotes, or nested lists
- No search index
- No live reload
- Hardcoded paths (`docs/` → `build/site/`)

This is intentionally minimal. It proves Gengoscript can build real tools.
