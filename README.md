# A Proxy for Package Registries with Mirroring and Guardrails

## The Vision

Supply chain attacks and malicious package publication is an increasing problem in software development, especially in high-volume package ecosystems like npm.

As a strategy to mitigate these, I propose a proxy system that is not concerned with hosting or additional concerns that introduce cost overhead and data retention complexity. The idea is to separate these concerns from the hosting concerns, entirely, allowing a user to choose hosting according to their need so long as it respects the normal protocol of the registry. For instance, a consumer could use codeartifact as their primary hosting provider.

## The Basic Requirements

The proxy for a given registry must be provided with the configuration for 3 registries of the same type, although the second two may be identical

1. The "public upstream" which is used to fetch packages that aren't present on the "private upstream". This upstream is the one where additional rules about what is "visible" are applied.
2. The "private upstream" which is the target for fetching packages by default, and which, when a package is found will be served immediately, with no further processing.
3. The "mirror target", which is the registry to which packages will be mirrored when they are fetched from the public upstream. When a package is requested that isn't present on the private upstream, but which is considered safe to mirror, this is where it will be mirrored to. As mentioned before, this CAN be the same registry as the private upstream, but doesn't have to be, such as in situations where you want to publish internal packages to some location, public ones to another, and have the private upstream be a union of the two, as might be common in a corporate setting.

# Architectural Plan

The system is built in layers. The top layers are registry-agnostic; only the
bottom layer knows about a specific registry protocol.

## RegistryClient Interface

The core abstraction is `RegistryClient` — a record of functions that any
registry (npm, PyPI, etc.) implements. Each function either fetches data from the
registry or parses a response into the proxy's internal metadata format.

```
type RegistryClient =
  { fetchMetadata    : PackageId -> '{IO, Exception} RegistryResponse
  , fetchArtifact    : PackageId -> Text -> '{IO, Exception} RegistryResponse
  , publishArtifact  : PackageId -> Text -> Bytes -> '{IO, Exception} (Either Text ())
  , parsePackageInfo : RegistryResponse -> Either Text PackageInfo
  , parseVersionInfo : RegistryResponse -> Text -> Either Text VersionInfo
  , parseVersionList : RegistryResponse -> Either Text [Text]
  }
```

The proxy is configured with **three** `RegistryClient` values — private
upstream, public upstream, and mirror target — and a `RuleSet`. Nothing in the
proxy core imports or references registry-specific types.

## Proxy Lifecycle

When a client requests a package:

1. **Private fetch**: call `fetchMetadata` on the private upstream.
2. **Success (2xx)**: forward the response body directly to the caller. Done.
3. **Miss (non-2xx)**: fall back to the public upstream.
4. **Public fetch**: call `fetchMetadata` on the public upstream.
5. **Parse**: use `parsePackageInfo` to extract internal `PackageInfo` metadata.
6. **Rules evaluation**: evaluate the `RuleSet` against the metadata.
   - Pure rules run first (scope checks, name allowlists — no IO).
   - If undecided, effectful rules run (CVE lookups).
   - If nothing allows the package, it is **denied by default**.
7. **Allowed**: mirror the response to the mirror target, then forward to the caller.
8. **Denied**: return a 403 with the denial reason.

Tarball/artifact requests follow the same pattern via `fetchArtifact`.

## Rules Engine

A deny-by-default, first-decisive-wins engine. Rules are split into two tiers:

- **Pure rules** — evaluated against `PackageInfo` / `VersionInfo` with no side
  effects. Fast and deterministic. Examples: `AllowScope "babel"`,
  `DenyDeprecated`, `DenyHasInstallScript`.
- **Effectful rules** — may perform IO (CVE database lookups, external policy
  checks). Only evaluated when no pure rule has decided. Examples: `DenyIfCVE`,
  `AllowIfNoCVE`.

If no rule produces a decision, the package is denied.

## CVE Indexing Subsystem

This subsystem will be responsible for indexing CVE databases, and providing an
interface for the rules engine to query whether a given package version has or
resolves any CVEs. Modelled as the `CVELookup` Unison ability so handlers can be
backed by in-memory caches, OSV.dev, or npm's bulk advisory endpoint.

## npm Implementation

The first `RegistryClient` implementation. Uses `@unison/http` for HTTP requests
and the existing `NpmRegistryTypes.Json` codecs to parse npm registry responses
into the internal `PackageInfo` / `VersionInfo` format.

## Setup

Requires [Nix](https://nixos.org/) with flakes enabled.

```sh
# enter the dev shell (or use direnv)
nix develop

# clone the project from Unison Share
ucm
npm-registry-types/main> pull @alexa/npm-registry-types/main
```

## Contributing

1. Make changes in `scratch.u` — UCM watches it and typechecks automatically.
2. `add` or `update` definitions in UCM.
3. Update the relevant transcript in `transcripts/` to reflect your changes.
4. Verify the transcript works from a clean state:
   ```sh
   ucm transcript transcripts/npm-registry-types.md
   ```
5. Push to Unison Share and commit the transcript diff.

Transcripts are reproducible markdown scripts that interleave Unison code with
UCM commands. They serve as a git-diffable record of the codebase and can
reconstruct it from scratch.

## License

This project is licensed under the BSD 3-Clause License - see the [LICENSE](LICENSE) file for details.
