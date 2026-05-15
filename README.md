# Unison Proxy

An npm registry proxy written in [Unison](https://www.unison-lang.org).

See the project README on [Unison Share](https://share.unison-lang.org/@alexa/npm-registry-types) for details.

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
