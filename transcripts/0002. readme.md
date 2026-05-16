# Project README

Sets up the project-level README doc that appears on Unison Share.

```ucm :hide
npm-registry-types/main> builtins.mergeio
npm-registry-types/main> lib.install @unison/base/releases/latest
npm-registry-types/main> lib.install @ceedubs/json/releases/1.4.2
```

## README

```unison
README : Doc
README = {{

# Unison Proxy

An npm registry proxy written in Unison, supporting use-cases like delayed
exposure, mirroring, and selective package filtering.

## Libraries

### npm-registry-types

Types modelling the npm registry wire protocol — the three core interactions
needed for package installation:

1. **Package metadata** (packument) — ''GET /package''
2. **Version metadata** — ''GET /package/version''
3. **Tarball download** — ''GET /package/-/name-version.tgz''

The registry supports two response formats for metadata, selected via the
''Accept'' header:

* **Abbreviated** ( {type NpmAbbreviatedPackument} ) — only the fields needed
  for dependency resolution and install. Requested with
  ''application/vnd.npm.install-v1+json''.
* **Full** ( {type NpmFullPackument} ) — everything including readme, publish
  times, star counts, and the complete package.json for each version.

#### Key types

{{ docTable
    [
      [{{ Type }}, {{ Purpose }}],
      [{{ {type NpmAbbreviatedVersion} }}, {{ Minimal version metadata for install }}],
      [{{ {type NpmFullVersion} }}, {{ Complete version metadata }}],
      [{{ {type NpmDist} }}, {{ Tarball URL, integrity hash, signatures }}],
      [{{ {type NpmPackageName} }}, {{ Scoped/unscoped name with URL encoding }}],
      [{{ {type NpmAcceptFormat} }}, {{ Content negotiation helper }}]
    ]
  }}

## License

BSD 3-Clause.

}}
```

```ucm
npm-registry-types/main> add
```
