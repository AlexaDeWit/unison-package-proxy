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
│   Rules Engine   │    Registry Ability       │  Pure + effectful rules │ abstract ops
├──────────────────┼──────────────────────────┤
│  CVE Ability     │    Internal Metadata      │  CVE lookups │ PackageInfo, VersionInfo
├──────────────────┴──────────────────────────┤
│          npm Registry Adapter                │  HTTP client, JSON codecs, type mapping
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

### 4. Registry Ability

The proxy core talks to registries through this ability. Each registry type
(npm, PyPI, etc.) provides a handler.

```
-- The response from a registry fetch (raw bytes + metadata)
type RegistryResponse =
  { statusCode : Nat
  , headers : [(Text, Text)]
  , body : Bytes
  , contentType : Text
  }

-- What a registry can do
ability Registry where
  -- Fetch package metadata (packument)
  fetchMetadata : PackageId -> {Registry} Either Text RegistryResponse
  -- Fetch a specific version's tarball
  fetchTarball : PackageId -> Text -> {Registry} Either Text RegistryResponse
  -- Publish/mirror a package (for mirror target)
  publishPackage : PackageId -> Text -> Bytes -> {Registry} Either Text ()
  -- Convert raw response to internal metadata (for rules evaluation)
  parsePackageInfo : RegistryResponse -> {Registry} Either Text PackageInfo
```

### 5. npm Registry Adapter

Maps between npm's wire types and the internal metadata format.

```
-- Convert NpmFullPackument → PackageInfo
npmToPackageInfo : NpmFullPackument -> PackageInfo

-- Convert NpmFullVersion → VersionInfo
npmToVersionInfo : PackageId -> NpmFullVersion -> VersionInfo

-- npm Registry handler (implements the Registry ability)
npmRegistryHandler : Text -> Request {Registry} a ->{IO, Exception} a
```

### 6. Proxy Core

Registry-agnostic logic. The proxy core doesn't know about npm.

```
handlePackageRequest : PackageId -> RuleSet
  -> {Registry, Registry, Registry, CVELookup} RegistryResponse
-- Three Registry instances: private, public, mirror
-- 1. Try private upstream
-- 2. On miss: fetch from public, parse metadata, evaluate rules
-- 3. If allowed: mirror, then serve
-- 4. If denied: return error
```

In practice, since Unison abilities are nominal, we'll likely need
wrapper types or different ability names for the three registries:

```
ability PrivateRegistry where ...
ability PublicRegistry where ...
ability MirrorTarget where ...
```

Or a single ability with an endpoint parameter.

### 7. HTTP Server

Thin layer that maps HTTP requests to proxy core operations.

## Implementation Phases

### Phase 1: Core Types (Current Session)

- PackageId, PackageInfo, VersionInfo, RuleContext
- CVERecord, Severity (data structures only)
- PureRule, EffectfulRule, RuleSet, RuleResult
- Pure rules evaluator (no abilities needed, fully testable)
- **Milestone**: `evaluatePureRule AllowAll ctx` returns `Allow`

### Phase 2: Registry Ability + npm Adapter

- Registry ability definition
- npm adapter: convert NpmFullPackument → PackageInfo, NpmFullVersion → VersionInfo
- npm Registry handler using @unison/http client
- **Milestone**: Fetch axios packument from npm, parse to PackageInfo

### Phase 3: Proxy Core Logic

- Private/public/mirror coordination
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

1. **Ability disambiguation**: How to express three Registry instances (private,
   public, mirror) in Unison's ability system? Options: wrapper abilities,
   explicit endpoint parameter, or handler composition.
2. **Streaming**: @unison/http supports chunked encoding — need to verify this
   works for tarball passthrough without buffering the full body.
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
