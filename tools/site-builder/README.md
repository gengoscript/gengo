# Gengoscript Site Builder

The static site generator behind <https://docs.gengoscript.org/>, written in
Gengoscript. Every docs deploy doubles as an end-to-end smoke test of the
language — the CI workflow builds the CLI and runs this script over `docs/`.

## Usage

From the repository root:

```bash
# Build the native CLI
zig build -Dpreset=1m cli

# Run the site builder (requires cap:fs)
./zig-out/bin/gengo --heap 4m --cap fs --mount root=. tools/site-builder/site-builder.gengo
```

This reads `.md` files from `docs/` and writes HTML to `build/site/`.
Paths are mount-based (`root/` maps to the repository root).

## What it does

- Converts the Markdown the docs actually use:
  - Headers (`#`, `##`, `###`), paragraphs, blockquotes, horizontal rules
  - Code blocks and inline code, with HTML escaping throughout; `gengo` fences
    receive grayscale syntax highlighting based on lexer keyword categories
  - Bold and italic, links, images
  - Unordered lists with one level of nesting, ordered lists
  - Tables (`| a | b |` with a `|---|` separator row)
- Orders chapters by the `chapterOrder` list (new pages land at the end)
- Adds a previous/contents/next footer to every page
- Generates the index page from `docs/index.md` plus a table of contents
- Emits per-page meta descriptions, canonical URLs, Open Graph tags, and
  `sitemap.xml`
- Ships the stylesheet alongside the pages

## Limitations

- No footnotes or deeper list nesting
- No search index
- No live reload

Intentionally minimal: it proves Gengoscript builds real tools — and finding
three VM bugs while writing it is exactly the point of dogfooding.
