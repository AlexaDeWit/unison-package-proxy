# Implementation Plan: Registry Proxy with Mirroring and Guardrails

## Revision Notes

**Rev 2 (2026-05-17)**: Major architectural revision. The initial plan over-indexed
on npm-specific implementation and rushed to a working proxy without building the
core abstractions. This revision corrects that by:

1. Introducing a **registry-agnostic internal metadata format** that rules evaluate against
2. Modeling the **registry as a Unison ability** so the proxy core is decoupled from npm
3. **Separating rules into pure and effectful** — pure rules (name matching, scope checks)
   run first without IO; effectful rules (CVE lookups, publish-time checks) run only if
   pure rules don't already decide
4. Defining **CVE data structures** even though the CVE subsystem is deferred — the rules
   engine interface must be complete
5. Building **bottom-up**: core types → abilities → rules engine → npm adapter → proxy server

## Architecture Layers

```
┌─────────────────────────────────────────────┐
│              HTTP Proxy Server               │  Unison HTTP server, routes
├─────────────────────────────────────────────┤
│              Proxy Core Logic                │  Private→public fallback, mirroring
├──────────────────┬──────────────────────────┤
│   Rules Engine   │  RegistryClient (record)  │  Pure + effectful rules │ fetch/parse ops
├──────────────────┼──────────────────────────┤
│  CVE Ability     │    Internal Metadata      │  CVE lookups │ PackageInfo, VersionInfo
├──────────────────┴──────────────────────────┤
│          npm RegistryClient impl             │  HTTP client, JSON codecs, type mapping
└─────────────────────────────────────────────┘
```

## Component Breakdown

### 1. Internal Metadata Types (Registry-Agnostic)

These are the types that the rules engine and proxy core operate on. They are
**not npm-specific** — any registry adapter maps its native types into these.

```
-- Identifies a package across any registry
type PackageId
  = PackageId.Unscoped Text
  | PackageId.Scoped Text Text    -- scope, name

-- Summary metadata about a package (what rules evaluate against)
type PackageInfo =
  { packageId : PackageId
  , description : Optional Text
  , license : Optional Text
  , maintainers : [Text]          -- email or username
  , keywords : [Text]
  , homepage : Optional Text
  , repository : Optional Text
  , latestVersion : Optional Text
  }

-- Metadata about a specific version (for version-level rules)
type VersionInfo =
  { packageId : PackageId
  , version : Text
  , publishedAt : Optional Text   -- ISO 8601 timestamp
  , deprecated : Optional Text
  , hasInstallScript : Boolean
  , dependencyCount : Nat         -- total deps
  , integrityHash : Optional Text -- SRI hash
  }

-- What the rules engine receives for evaluation
type RuleContext =
  { packageInfo : PackageInfo
  , versionInfo : Optional VersionInfo  -- None for packument-level requests
  }
```

### 2. CVE Data Structures

Even though the CVE subsystem implementation is deferred, the types must exist
so the rules engine interface is complete.

```
type Severity = Severity.Low | Severity.Medium | Severity.High | Severity.Critical

type CVERecord =
  { cveId : Text
  , summary : Text
  , severity : Severity
  , affectedVersions : [Text]   -- semver ranges (strings for now)
  , fixedVersions : [Text]
  , publishedAt : Optional Text
  }

-- The ability for CVE lookups (effectful)
ability CVELookup where
  lookupCVEs : PackageId -> {CVELookup} [CVERecord]
  hasActiveCVE : PackageId -> Text -> {CVELookup} Boolean  -- pkg, version
```

### 3. Rules Engine

**Key insight**: Rules are split into two phases:

1. **Pure rules** — evaluated against `RuleContext` with no side effects. Fast, deterministic.
   Examples: allow by name, allow by scope, deny deprecated.
2. **Effectful rules** — may perform IO (CVE lookups, external policy checks).
   Only evaluated if no pure rule has already decided.

```
-- A pure rule: evaluated against metadata only
type PureRule
  = PureRule.AllowAll
  | PureRule.AllowPackage PackageId
  | PureRule.AllowScope Text
  | PureRule.DenyDeprecated
  | PureRule.DenyHasInstallScript

-- An effectful rule: may perform side effects
type EffectfulRule
  = EffectfulRule.DenyIfCVE        -- deny if any active CVE
  | EffectfulRule.AllowIfNoCVE     -- explicit allow if no CVEs found

-- Combined rule set
type RuleSet =
  { pureRules : [PureRule]
  , effectfulRules : [EffectfulRule]
  }

type RuleResult
  = RuleResult.Allow Text         -- reason
  | RuleResult.Deny Text          -- reason
  | RuleResult.NoDecision         -- this rule doesn't apply

-- Pure evaluation: no abilities needed
evaluatePureRule : PureRule -> RuleContext -> RuleResult

-- Effectful evaluation: needs CVELookup ability
evaluateEffectfulRule : EffectfulRule -> RuleContext -> {CVELookup} RuleResult

-- Full evaluation: pure first, then effectful if undecided
evaluateRuleSet : RuleSet -> RuleContext -> {CVELookup} RuleResult
```

### 4. Registry Client Interface

Instead of an ability, the registry interface is a **record of functions**
(`RegistryClient`). This solves the multiple-instance problem naturally: three
registries are just three record values. It also maps directly to the
type-class/interface mental model.

```
-- Raw response from any registry operation
type RegistryResponse =
  { statusCode : Nat
  , responseHeaders : [(Text, Text)]
  , responseBody : Bytes
  , contentType : Text
  }

isSuccess : Nat -> Boolean
isSuccess code = (code >= 200) && (code < 300)

-- The interface that npm, PyPI, etc. each implement
type RegistryClient =
  { fetchMetadata    : PackageId -> '{IO, Exception} RegistryResponse
  , fetchArtifact    : PackageId -> Text -> '{IO, Exception} RegistryResponse
  , publishArtifact  : PackageId -> Text -> Bytes -> '{IO, Exception} (Either Text ())
  , parsePackageInfo : RegistryResponse -> Either Text PackageInfo
  , parseVersionInfo : RegistryResponse -> Text -> Either Text VersionInfo
  , parseVersionList : RegistryResponse -> Either Text [Text]
  }
```

Key design points:

- **Fetch operations** return `RegistryResponse` with status code + raw body.
  The proxy checks `statusCode` to decide serve-vs-fallback before parsing.
- **Parse operations** are pure — they extract internal metadata from a
  response without IO. Each registry provides its own parsing logic.
- **Multiple instances are trivial** — `ProxyConfig` holds three `RegistryClient`
  values (private, public, mirror). No ability disambiguation needed.

### 5. npm RegistryClient Implementation

The first `RegistryClient` implementation, using `@unison/http` for HTTP
and the existing `NpmRegistryTypes.Json` codecs for parsing.

```
-- Construct an npm client for a given base URL
npmClient : Text -> RegistryClient

-- Internal: convert NpmFullPackument → PackageInfo
npmToPackageInfo : NpmFullPackument -> PackageInfo

-- Internal: convert NpmFullVersion → VersionInfo
npmToVersionInfo : PackageId -> NpmFullVersion -> VersionInfo
```

### 6. Proxy Core

Registry-agnostic logic. The proxy core operates on `RegistryClient` values
and never imports npm-specific types.

The proxy lifecycle for a metadata request:

```
-- 1. Fetch from private upstream
privateResp = !(RegistryClient.fetchMetadata config.private pkgId)
-- 2. If 2xx → stream responseBody to caller, done
if isSuccess (RegistryResponse.statusCode privateResp) then
  toHttpResponse privateResp
else
  -- 3. Fetch from public upstream
  publicResp = !(RegistryClient.fetchMetadata config.public pkgId)
  if isSuccess (RegistryResponse.statusCode publicResp) then
    -- 4. Parse metadata for rules evaluation
    match RegistryClient.parsePackageInfo config.public publicResp with
      Right info ->
        ctx = RuleContext info None
        match evaluateRuleSet config.rules ctx with
          -- 5. Rules allow → mirror + stream to caller
          RuleDecision.Allow _ ->
            !(RegistryClient.publishArtifact config.mirror pkgId ...)
            toHttpResponse publicResp
          -- 6. Rules deny → 403
          RuleDecision.Deny reason -> forbiddenResponse reason
```

### 7. HTTP Server

Thin layer that maps HTTP requests to proxy core operations.

## Implementation Phases

### Phase 1: Core Types + RegistryClient (Done)

- PackageId, PackageInfo, VersionInfo, RuleContext
- CVERecord, Severity (data structures only)
- PureRule, EffectfulRule, RuleSet, RuleDecision
- RegistryResponse, RegistryClient record, isSuccess
- Pure + effectful rules evaluators
- **Milestone**: All types and evaluation functions typecheck ✓

### Phase 2: npm RegistryClient Implementation

- `npmClient : Text -> RegistryClient`
- Convert NpmFullPackument → PackageInfo, NpmFullVersion → VersionInfo
- HTTP fetch using @unison/http client
- **Milestone**: Fetch axios packument from npm, parse to PackageInfo

### Phase 3: Proxy Core Logic

- Private/public/mirror coordination using three RegistryClient values
- Rules evaluation wired into the fetch path
- **Milestone**: Deny-by-default works — unlisted packages are rejected

### Phase 4: HTTP Server + Integration

- HTTP server using @unison/http
- Request routing (packument vs tarball)
- Integration test: npm client → proxy → npm registry

### Phase 5: CVE Ability (Deferred)

- CVELookup ability handler
- Effectful rules wired in
- Advisory data source integration

## Open Questions (Updated)

1. ~~**Ability disambiguation**~~: Solved by using `RegistryClient` record
   instead of an ability. Three registries are three record values.
2. **Streaming**: `RegistryResponse.responseBody` is currently `Bytes` (fully
   buffered). For large tarballs, investigate @unison/http chunked encoding
   to avoid buffering the full body in memory.
3. **Semver parsing**: Needed for CVE version range matching. No existing library
   found on Unison Share. Can defer until Phase 5.
4. **Rule serialization**: Rules need to be loadable from config. JSON encoding
   of the rule types, or a simple DSL?

---

## Implementation Order (Recommended)

### Phase 1: Proxy Skeleton (Sessions 1-2)

- Install `@unison/http`
- Implement a minimal pass-through proxy: receive request → forward to single upstream → return response
- No rules, no mirroring — just prove the HTTP plumbing works
- **Milestone**: `npm install express` works through the proxy

### Phase 2: Registry Abstraction + Dual Upstream (Sessions 3-4)

- Define the `Registry` ability
- Implement npm handler with proper Accept header handling
- Add private/public upstream split (try private first, fall back to public)
- **Milestone**: Proxy correctly routes to private upstream, falls through to public

### Phase 3: Rules Engine (Session 5)

- Define rule types
- Implement evaluator (pure function, easily testable)
- Wire into proxy flow (between "fetch from public" and "serve response")
- Start with simple rules: AllowScope, AllowPackage, AllowExact
- **Milestone**: Packages not in the allow list are denied with a clear error

### Phase 4: Mirroring (Session 6)

- After a successful public fetch that passes rules, publish to mirror target
- For packuments: re-encode and PUT to mirror
- For tarballs: stream to mirror target
- **Milestone**: First fetch from public → mirrored to private; second fetch hits private directly

### Phase 5: CVE Integration (Sessions 7-8)

- Model CVE types
- Implement npm bulk advisory client
- Add polling loop with in-memory cache
- Wire `AllowIfNoCVE` rule into the engine
- **Milestone**: Package with known CVE is blocked; patched version is allowed

### Phase 6: Polish & Production Readiness (Sessions 9-10)

- Error handling and graceful degradation (upstream timeouts, CVE service down)
- Logging and observability
- Configuration validation
- Integration test suite (mock upstreams)
- Documentation and README on Unison Share

---

## Open Questions

1. **Does `@unison/http` support streaming responses?** Critical for tarball proxying. If not, need to buffer or find an alternative.
2. **How to handle npm's ETag/If-None-Match caching?** The proxy should pass these through for efficiency.
3. **Semver range parsing in Unison**: CVE advisories specify affected version ranges. Is there a semver library on Unison Share, or do we need to build one?
4. **Authentication forwarding**: Should the proxy forward auth tokens to private upstream? Needed for corporate registries (CodeArtifact, Artifactory).
5. **Concurrent requests**: When many packages are requested simultaneously (typical npm install), how does the proxy handle concurrency? Unison has structured concurrency via abilities — need to investigate.

## Dependencies (Unison Share Libraries)

| Library          | Purpose              | Status                             |
| ---------------- | -------------------- | ---------------------------------- |
| `@unison/http`   | HTTP client + server | Available, needs investigation     |
| `@unison/routes` | HTTP routing DSL     | Available, alternative to raw http |
| `@ceedubs/json`  | JSON encode/decode   | Already installed                  |
| `@unison/base`   | Standard library     | Already installed                  |
| `@gvolpe/cache`  | In-memory caching    | Available, may help with CVE index |

## Risk Assessment

| Risk                                 | Impact | Likelihood | Mitigation                                                                        |
| ------------------------------------ | ------ | ---------- | --------------------------------------------------------------------------------- |
| `@unison/http` lacks streaming       | High   | Medium     | Buffer small responses; reject oversized tarballs; contribute streaming upstream  |
| Unison performance for large JSON    | Medium | Medium     | Profile early; consider passing through raw bytes for non-inspected responses     |
| CVE data quality/completeness        | Medium | High       | Start with npm's own advisory API; add sources incrementally                      |
| Unison ecosystem gaps (semver, etc.) | Medium | Medium     | Build minimal implementations as needed; contribute back                          |
| Complexity creep in rules            | Low    | Medium     | Keep v1 rules dead simple; resist adding features until real usage informs design |
