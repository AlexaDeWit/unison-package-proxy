# Implementation Plan: Registry Proxy with Mirroring and Guardrails

## Effort Estimate Summary

| Component | Estimated Effort | Confidence | Notes |
|---|---|---|---|
| Registry Abstraction (ability) | Small | High | Type-level design, thin ability interface |
| NPM Registry Implementation | Medium | High | HTTP client calls, JSON codecs (mostly done) |
| Rules Engine | Medium | Medium | Core logic is simple, but rule DSL design matters |
| CVE Indexing Subsystem | Large | Low | External API integration, polling/caching, data model |
| HTTP Server (proxy itself) | Medium | Medium | Request routing, content negotiation, streaming |
| Configuration | Small | High | Static config type, parsed at startup |
| Integration & Testing | Large | Medium | End-to-end correctness across all components |
| **Total** | **~6-10 focused work sessions** | | Assuming single developer, iterative |

### Key factors affecting effort

1. **Unison ecosystem maturity**: `@unison/http` provides both client and server, but docs are sparse. Expect discovery overhead.
2. **No persistent storage library**: CVE indexing needs caching. `@gvolpe/cache` exists but may not fit. Could need a custom in-memory solution or file-based approach.
3. **Streaming/large payloads**: Full packuments can exceed 10MB. Proxy must handle these efficiently — Unison's streaming story needs investigation.
4. **The "deny by default" rules engine is conceptually simple** but the UX of configuring it (rule format, ordering, update mechanism) adds design surface.

---

## Component Breakdown

### 1. Registry Abstraction (Ability)

**What it is**: A Unison ability that abstracts over registry operations, making the proxy logic registry-agnostic.

**Approach**:
```
ability Registry where
  fetchPackument : PackageName -> AcceptFormat -> {Registry} Optional Packument
  publishPackage : PackageName -> Version -> Bytes -> {Registry} PublishResult
  searchPackages : SearchQuery -> {Registry} SearchResults
```

**Design decisions**:
- Model as a Unison ability so different registry backends (npm, future: PyPI, crates.io) are just different handlers
- The proxy core operates generically over `{Registry}` — doesn't know about npm specifics
- Start with read-only operations (fetch/search); publish/mirror is a separate concern

**Effort**: Small — this is mostly type design. The interesting work is in the npm handler.

---

### 2. NPM Registry Implementation

**What it is**: The handler for the `Registry` ability that speaks the npm registry HTTP protocol.

**Current state**: Types are fully modelled (`NpmRegistryTypes.Types`), JSON codecs are mostly complete (`NpmRegistryTypes.Json`). What remains:
- HTTP client calls using `@unison/http`
- Response parsing (handle both abbreviated and full Accept headers)
- Error handling (404 = not found, 5xx = upstream error, timeouts)
- Tarball proxying (streaming passthrough, no need to parse)

**Approach**:
1. Install `@unison/http`
2. Implement `NpmRegistryClient` ability handler:
   - `GET /{package}` with appropriate Accept header → parse JSON → return typed packument
   - `GET /{package}/-/{name}-{version}.tgz` → stream tarball bytes
3. Wire the typed packument through the existing decoders

**Key risk**: Tarball streaming. If `@unison/http` doesn't support streaming responses, large tarballs will need to be buffered in memory. Need to investigate.

**Effort**: Medium — HTTP plumbing is straightforward but the Accept header content negotiation and error handling add surface.

---

### 3. Rules Engine

**What it is**: Deny-by-default, first-allow-wins rule evaluator. When a package is requested from the public upstream, each rule is checked in order until one allows it.

**Approach**:
```
type Rule
  = AllowExact PackageName Version        -- allow specific package@version
  | AllowPackage PackageName              -- allow any version of a package
  | AllowScope Text                       -- allow everything in @scope/*
  | AllowIfNoCVE PackageName              -- allow if no known CVEs
  | AllowAfterDelay PackageName Duration  -- allow after N days since publish
  | AllowAll                              -- escape hatch (dangerous)

type RuleResult = Allow | Deny Text

evaluateRules : [Rule] -> PackageName -> Version -> {CVEIndex} RuleResult
evaluateRules rules pkg ver =
  -- first rule that returns Allow wins; if none match, Deny
```

**Design decisions**:
- Rules are a simple sum type — easy to serialize, explain, and test
- The engine is a pure function over rules + package info + CVE data
- Rules reference the `CVEIndex` ability for CVE-aware rules
- Configuration is a static list (loaded at startup), not a dynamic database
- Future: could add `AllowIfMaintainerTrusted`, `AllowIfNoNewDeps`, etc.

**Effort**: Medium — the evaluator itself is trivial, but designing the right set of initial rules and their serialization format takes iteration.

---

### 4. CVE Indexing Subsystem

**What it is**: Polls CVE databases and provides a queryable interface for the rules engine.

**Approach**:
```
ability CVEIndex where
  hasActiveCVE : PackageName -> Version -> {CVEIndex} Boolean
  getCVEs : PackageName -> {CVEIndex} [CVERecord]
  resolvesCVE : PackageName -> Version -> CVEId -> {CVEIndex} Boolean
```

**Data sources** (in priority order):
1. **OSV.dev API** (`https://api.osv.dev/v1/query`) — free, covers npm, structured JSON
2. **npm audit bulk endpoint** (`/-/npm/v1/security/advisories/bulk`) — already in the OpenAPI spec
3. **GitHub Advisory Database** — comprehensive but requires API token

**Implementation plan**:
1. Start with npm's own bulk advisory endpoint (it's already in scope)
2. Model `CVERecord` type (id, affected versions, severity, fixed versions)
3. Implement a polling loop that refreshes the index periodically
4. Store in-memory (Map PackageName [CVERecord]) with a TTL
5. Later: add OSV.dev for broader coverage

**Key risk**: This is the most uncertain component. CVE data is messy — version ranges, withdrawn advisories, conflicting sources. The "does this version resolve a CVE?" question is particularly tricky (requires semver range parsing).

**Effort**: Large — external API integration, semver range matching, caching strategy, polling lifecycle.

---

### 5. HTTP Server (The Proxy)

**What it is**: The actual HTTP server that clients (npm CLI) talk to.

**Approach using `@unison/http` or `@unison/routes`**:

```
-- Routing pseudocode
handleRequest : HttpRequest -> {Registry, CVEIndex, Mirror} HttpResponse
handleRequest req = match (method req, path req) with
  (GET, PackagePath pkg) ->
    -- 1. Try private upstream
    -- 2. If not found, check rules against public upstream
    -- 3. If allowed, fetch, mirror, serve
    -- 4. If denied, return 404 or 403 with reason
  (GET, TarballPath pkg ver) ->
    -- Stream from private upstream, fall back to public with rules check
  _ -> notFound
```

**Key operations in the proxy flow**:
1. Parse incoming request → extract package name + format
2. Check private upstream (fast path — no rules needed)
3. On miss: fetch from public upstream
4. Evaluate rules engine against the package
5. If allowed: mirror to mirror target, then serve response
6. If denied: return error explaining why

**Effort**: Medium — the routing/handling is straightforward, but the three-registry coordination (private → public → mirror) and error propagation need care.

---

### 6. Configuration

**What it is**: Static configuration defining the three registries and the rule set.

**Approach**:
```
type ProxyConfig =
  { publicUpstream : RegistryEndpoint
  , privateUpstream : RegistryEndpoint
  , mirrorTarget : RegistryEndpoint
  , rules : [Rule]
  , cvePollingInterval : Duration
  , listenPort : Nat
  }

type RegistryEndpoint =
  { baseUrl : Text
  , authToken : Optional Text
  }
```

**Format**: JSON file loaded at startup. No hot-reloading in v1.

**Effort**: Small — just types + a JSON decoder.

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

| Library | Purpose | Status |
|---|---|---|
| `@unison/http` | HTTP client + server | Available, needs investigation |
| `@unison/routes` | HTTP routing DSL | Available, alternative to raw http |
| `@ceedubs/json` | JSON encode/decode | Already installed |
| `@unison/base` | Standard library | Already installed |
| `@gvolpe/cache` | In-memory caching | Available, may help with CVE index |

## Risk Assessment

| Risk | Impact | Likelihood | Mitigation |
|---|---|---|---|
| `@unison/http` lacks streaming | High | Medium | Buffer small responses; reject oversized tarballs; contribute streaming upstream |
| Unison performance for large JSON | Medium | Medium | Profile early; consider passing through raw bytes for non-inspected responses |
| CVE data quality/completeness | Medium | High | Start with npm's own advisory API; add sources incrementally |
| Unison ecosystem gaps (semver, etc.) | Medium | Medium | Build minimal implementations as needed; contribute back |
| Complexity creep in rules | Low | Medium | Keep v1 rules dead simple; resist adding features until real usage informs design |
