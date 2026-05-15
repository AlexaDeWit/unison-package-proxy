# Agent Guide: unison-proxy

## Project overview

This is a Unison project. Unison stores code in a content-addressed codebase
(SQLite at `~/.unison/v2/`), not in text files. The codebase is the source of
truth and is synced via Unison Share. Git tracks configuration, research notes,
and transcripts — not source code.

## Dev environment

- **Nix flake** provides `ucm` (Unison Codebase Manager) via `nix develop`
- **direnv** auto-loads via `.envrc`
- UCM project: `npm-registry-types` on branch `main`
- Libraries installed: `@unison/base`, `@ceedubs/json`

## Workflow: editing code

1. **Always work in `scratch.u`**. UCM watches this file and typechecks on
   save. Never create other `.u` files.
2. Use the Unison MCP server to typecheck:
   - tool: `mcp_unison_typecheck-code`
   - `projectContext`: `{"projectName": "npm-registry-types", "branchName": "main"}`
   - `code`: `{"filePath": "/home/alexa/Workspace/unison-proxy/scratch.u"}`
3. Iterate in `scratch.u` until the user accepts the changes.
4. The **user** will run `update` or `add` in UCM to commit definitions to the
   codebase. Do not run `update` on the user's behalf unless explicitly asked.
5. After the user has updated the codebase, generate a transcript in
   `transcripts/` that records the new code. See "Transcripts" below.

## Workflow: transcripts

Transcripts are markdown files in `transcripts/` that interleave Unison code
blocks with UCM commands. They serve as a git-diffable record of the codebase
and can reconstruct it from scratch.

A transcript has two block types:

- ` ```unison ` — Unison source code (like writing to `scratch.u`)
- ` ```ucm ` — UCM commands (like typing at the UCM prompt)

Structure a transcript like this:

````markdown
# Title

Description of what this transcript sets up.

` ```ucm :hide `
npm-registry-types/main> builtins.mergeio
npm-registry-types/main> lib.install @unison/base/releases/latest
npm-registry-types/main> lib.install @ceedubs/json/releases/1.4.2
` ``` `

## Section Name

` ```unison `
-- definitions here
` ``` `

` ```ucm `
npm-registry-types/main> add
` ``` `
````

Key rules:

- Use `:hide` on setup blocks (builtins, lib installs) to keep output clean.
- Split code into sections with `add` after each so later types can reference
  earlier ones.
- Only generate a transcript **after** the user has accepted the code and run
  `update`/`add` in UCM.

Run a transcript: `ucm transcript transcripts/my-transcript.md`

## Unison language constraints

- **Sum type variants cannot use inline `{ }` record syntax.** If a variant
  needs named fields, define a separate record type and reference it.

  ```
  -- WRONG: will not parse
  type Foo = Bar { x : Nat, y : Text } | Baz

  -- RIGHT: extract a record
  type BarFields = { x : Nat, y : Text }
  type Foo = Bar BarFields | Baz
  ```

- Record types use `type MyRecord = { field1 : Type1, field2 : Type2 }`.
- Pattern matching on records is positional or via accessor functions
  (e.g., `MyRecord.field1 value`).
- `unique type` is the default; just write `type`.

## Unison first-class documentation

Unison has a built-in `Doc` type for rich documentation. Key syntax:

### Creating docs

```
myDoc : Doc
myDoc = {{ This is a documentation block. }}
```

Anonymous docs (placed immediately above a definition) auto-link as
`definitionName.doc`:

```
{{ Brief description of myFunction. }}
myFunction : Nat -> Text
myFunction n = ...
```

### Formatting

| Feature            | Syntax                                               |
| ------------------ | ---------------------------------------------------- |
| Heading            | `# Heading`                                          |
| Bold               | `**text**` or `__text__`                             |
| Italic             | `*text*` or `_text_`                                 |
| Monospace          | `''text''` (two single quotes)                       |
| Inline Unison code | ` ``expression`` ` (two backticks — **typechecked**) |
| Bullet list        | `* item`                                             |
| Numbered list      | `1. item`                                            |
| Term link          | `{myTerm}`                                           |
| Type link          | `{type MyType}`                                      |
| Named term link    | `[display text]({myTerm})`                           |
| Named type link    | `[display text]({type MyType})`                      |
| Source embed       | `@source{myTerm}`                                    |
| Signature embed    | `@signature{myTerm}`                                 |
| Inline signature   | `@inlineSignature{myTerm}`                           |
| Sub-doc include    | `{{ otherDoc }}`                                     |
| External link      | `[text](https://example.com)`                        |

### Critical distinctions

- **` ``double backticks`` `** create typechecked inline Unison code. The
  content must be valid Unison. Curly braces inside will be parsed as term/type
  links. Do NOT use these for arbitrary text like HTTP paths or headers.
- **`''two single quotes''`** create monospace text without typechecking. Use
  these for non-Unison content (URLs, HTTP methods, header values, etc.).

### Tables

Markdown pipe tables (`| col | col |`) are **NOT** valid in Unison docs. Use
`{{ docTable }}` instead:

```
{{ docTable
    [
      [{{ Header 1 }}, {{ Header 2 }}],
      [{{ row 1 col 1 }}, {{ row 1 col 2 }}]
    ]
  }}
```

### Executable code blocks

Triple backticks inside a doc create executable, evaluated code blocks. A blank
line must appear before and after the fenced block:

```
{{
    Examples:

    ` `` `
    myFunction 42
    ` `` `
}}
```

### Project README

A `README : Doc` term at the project root becomes the project page on Unison
Share. Define it in `scratch.u`, `add` it via UCM, then push to Share.

## Files overview

| Path              | Purpose                                  | Git-tracked     |
| ----------------- | ---------------------------------------- | --------------- |
| `scratch.u`       | Working scratchpad for UCM               | No (gitignored) |
| `transcripts/`    | Reproducible records of codebase changes | Yes             |
| `research-notes/` | Reference material (OpenAPI specs, etc.) | Yes             |
| `flake.nix`       | Nix dev environment providing `ucm`      | Yes             |
| `.envrc`          | direnv integration                       | Yes             |

## MCP tools available

- `mcp_unison_typecheck-code` — typecheck without modifying codebase
- `mcp_unison_update-definitions` — typecheck and commit to codebase
- `mcp_unison_docs` — fetch docs for a definition
- `mcp_unison_search-by-type` — search by type signature
- `mcp_unison_run` — execute a definition
- `mcp_unison_share-project-search` — search Unison Share
- `mcp_unison_share-project-readme` — fetch a Share project's README
- `mcp_unison_lib-install` — install a library
- `mcp_unison_list-local-projects` — list local projects
- `mcp_unison_list-project-branches` — list branches
- `mcp_unison_list-project-libraries` — list installed libraries
