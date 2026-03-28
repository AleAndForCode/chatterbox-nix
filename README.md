# chatterbox-nix

[Chatterbox](https://github.com/resemble-ai/chatterbox) nix packages.

## Motivation

[Chatterbox](https://github.com/resemble-ai/chatterbox) is a useful Python TTS project, but its upstream Python dependency graph is not packaged cleanly enough to be consumed directly from `nixpkgs` today, especially with CUDA-enabled PyTorch.
This repository exists as a practical nixification workspace:
- provide reusable Chatterbox flake packages now;
- keep packaging logic separate from the upstream source tree;
- keep CUDA-specific packaging and `uv2nix` overrides in one place;
- make later upstreaming or migration into `nixpkgs` easier.

## What This Is

`chatterbox-nix` is a flake that packages pinned upstream Chatterbox sources from GitHub using `uv2nix` / `pyproject.nix`.

Supported platform today:
- `x86_64-linux`

Current package set:
- `chatterbox`: base Python package derivation;
- `chatterbox-python`: wrapped CPU Python runtime with Chatterbox and its Python/native runtime deps;
- `chatterbox-cuda`: CUDA-enabled Python package derivation;
- `chatterbox-cuda-python`: wrapped CUDA Python runtime intended for actual usage;
- `chatterbox-gradio-cuda`: launcher for the upstream `gradio_tts_app.py` sample.

The main practical output is `chatterbox-cuda-python`.

## Usage

### Add flake input

```nix
{
  inputs.chatterbox-nix.url = "github:AleAndForCode/chatterbox-nix";

  outputs = { self, nixpkgs, chatterbox-nix, ... }:
  let
    system = "x86_64-linux";
  in {
    packages.${system}.default = chatterbox-nix.packages.${system}.chatterbox-cuda;
  };
}
```

### Open wrapped CUDA Python runtime

```bash
nix shell github:AleAndForCode/chatterbox-nix#chatterbox-cuda-python
```

### Smoke test imports and CUDA visibility

```bash
nix shell github:AleAndForCode/chatterbox-nix#chatterbox-cuda-python -c python -c "import chatterbox, torch, torchaudio, gradio; print(torch.cuda.is_available())"
```

### Run upstream Gradio sample

```bash
nix run github:AleAndForCode/chatterbox-nix#chatterbox-gradio-cuda
```

### Run checks

```bash
nix flake check
```

## Notes

- The flake pins upstream Chatterbox source from GitHub.
- The flake reads `pyproject.toml` from pinned upstream Chatterbox sources, but keeps its own `uv.lock` for reproducible dependency resolution.
- The flake currently supports only `x86_64-linux`.
- CUDA support relies on nixpkgs `torchWithCuda` / `torchaudio` packaging and requires `allowUnfree = true`.
- Some transitive Python dependencies still need explicit `uv2nix` overrides because their upstream metadata is incomplete.

## CUDA Binary Cache

CUDA-heavy builds are much faster if you enable the NixOS CUDA cache before using this flake.

Example NixOS config:
```nix
nix.settings = {
  extra-substituters = [
    "https://cache.nixos-cuda.org"
    "https://nix-community.cachix.org"
  ];

  extra-trusted-public-keys = [
    "cache.nixos-cuda.org:74DUi4Ye579gUqzH4ziL9IyiJBlDpMRn9MBN8oNan9M="
    "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
  ];
};
```

## Maintaining `uv.lock`

Upstream Chatterbox does not currently publish a `uv.lock`, so this repository owns the lockfile used by `uv2nix`.

When upstream changes:

1. Update the pinned upstream source in `flake.nix` and refresh `flake.lock`.
2. Check the new upstream [pyproject.toml](https://github.com/resemble-ai/chatterbox/blob/main/pyproject.toml) for dependency changes.
3. In a temporary checkout of upstream Chatterbox, generate a fresh lock with `uv lock`.
4. Copy the resulting `uv.lock` into this repository root.
5. Run:
   `nix flake check`
6. If the build breaks, update the `uv2nix` override layer in `flake.nix` for the newly exposed package defects.

Recommended update workflow:

```bash
git clone https://github.com/resemble-ai/chatterbox.git /tmp/chatterbox-upstream
cd /tmp/chatterbox-upstream
uv lock
cp uv.lock /path/to/your/chatterbox-nix/uv.lock
cd /path/to/your/chatterbox-nix
nix flake check
```

What to watch for after an update:

- new undeclared Python build dependencies such as `setuptools`;
- new native runtime libraries that need to be added to wrappers or package overrides;
- changes in PyTorch / torchaudio compatibility that affect CUDA packaging.

## Project Goals

Package Chatterbox cleanly enough that the Nix-specific compatibility layer can shrink over time and eventually resemble a proper `nixpkgs`-quality package.

This repository serves as the Chatterbox nixification workspace.
