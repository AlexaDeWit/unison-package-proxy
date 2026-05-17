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

The architecture will be separated into the following components:

## A Rules Engine

A rules engine based on a simple notion... Deny by default.

By default no packages are available, then when checking for a specific package, the engine will check the public upstream, and iterate through each rule. Once a rule allows the package to be consumed, checks cease.

The reason for this deny-by-default and first-allow-wins approach is that it is reasonably straightforward, and easy to explain to consumers. Additionally it simplifies the various cases where a more complex system would allow various escape hatches, such as when a CVE may need to be addressed, expediting what would otherwise be a timeout restriction.

## CVE Indexing Subsystem

This subsystem will be responsible for indexing CVE databases, and providing an interface for the rules engine to query whether a given package version has or resolves and CVEs.

## Registry Abstraction

This will abstract over the specific registry's API protocol, as well as formatting data to be used by the rules engine.

## NPM Registry Implementation

As the first registry to be implemented, this will implement the registry abstraction for the npm registry, and will be the primary focus of this project.

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
