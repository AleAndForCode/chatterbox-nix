{
  description = "Chatterbox Nix flake";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    chatterboxSrc = {
      url = "github:resemble-ai/chatterbox";
      flake = false;
    };

    pyproject-nix = {
      url = "github:pyproject-nix/pyproject.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    uv2nix = {
      url = "github:pyproject-nix/uv2nix";
      inputs.pyproject-nix.follows = "pyproject-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    pyproject-build-systems = {
      url = "github:pyproject-nix/build-system-pkgs";
      inputs.pyproject-nix.follows = "pyproject-nix";
      inputs.uv2nix.follows = "uv2nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      chatterboxSrc,
      pyproject-nix,
      uv2nix,
      pyproject-build-systems,
      ...
    }:
    let
      lib = nixpkgs.lib;
      supportedSystems = [ "x86_64-linux" ];
      forEachSystem = lib.genAttrs supportedSystems;
      pkgsFor =
        system:
        import nixpkgs {
          inherit system;
          config.allowUnfree = true;
        };

      pyproject = lib.importTOML (chatterboxSrc + "/pyproject.toml");
      uvLock = uv2nix.lib.lock1.parseLock (lib.importTOML ./uv.lock);
      localPackages = lib.filter uv2nix.lib.lock1.isLocalPackage uvLock.package;
      workspaceProjects = uv2nix.lib.lock1.getLocalProjects {
        lock = uvLock;
        inherit localPackages;
        workspaceRoot = chatterboxSrc;
      };
      workspaceConfig = uv2nix.lib.workspace.loadConfig pyproject (
        (map (project: project.pyproject) (lib.attrValues workspaceProjects))
        ++ lib.optional (!(pyproject ? project)) pyproject
      );
      lockOverlay = uv2nix.lib.overlays.mkOverlay {
        sourcePreference = "wheel";
        environ = { };
        spec = {
          "chatterbox-tts" = [ ];
        };
        localProjects = workspaceProjects;
        config = workspaceConfig;
        workspaceRoot = chatterboxSrc;
        lock = uvLock;
      };

      mkPyprojectOverrides =
        system:
        final: prev:
        let
          pkgs = pkgsFor system;
          inherit (final) resolveBuildSystem;
        in
        {
          antlr4-python3-runtime = prev.antlr4-python3-runtime.overrideAttrs (old: {
            nativeBuildInputs =
              (old.nativeBuildInputs or [ ])
              ++ resolveBuildSystem {
                setuptools = [ ];
              };
          });

          sox = prev.sox.overrideAttrs (old: {
            nativeBuildInputs =
              (old.nativeBuildInputs or [ ])
              ++ resolveBuildSystem {
                setuptools = [ ];
              };
          });

          numba = prev.numba.overrideAttrs (old: {
            buildInputs = (old.buildInputs or [ ]) ++ [ pkgs.onetbb ];
          });

          sympy = prev.sympy.overrideAttrs (old: {
            dependencies = (old.dependencies or { }) // {
              mpmath = [ ];
            };
            passthru = (old.passthru or { }) // {
              dependencies = ((old.passthru.dependencies or { }) // {
                mpmath = [ ];
              });
            };
          });
        };

      mkPackagePythonSet =
        system: enableCuda:
        let
          pkgs = pkgsFor system;
          python = pkgs.python312;
          pythonBase = pkgs.callPackage pyproject-nix.build.packages {
            inherit python;
          };
          torchOverlay =
            final: prev:
            let
              basePy = pkgs.python312Packages;
              torch = if enableCuda then basePy.torchWithCuda else basePy.torch;
            in
            {
              inherit torch;
              torchaudio =
                if enableCuda then
                  basePy.torchaudio.override {
                    inherit torch;
                    cudaSupport = true;
                    cudaPackages = pkgs.cudaPackages;
                  }
                else
                  basePy.torchaudio;
            };
        in
        pythonBase.overrideScope (
          lib.composeManyExtensions [
            pyproject-build-systems.overlays.wheel
            lockOverlay
            (mkPyprojectOverrides system)
            torchOverlay
          ]
        );

      resolveRuntimeDeps =
        pythonSet: rootDeps:
        let
          recurse =
            seen: item:
            let
              pkg =
                if builtins.isString item then
                  if builtins.hasAttr item pythonSet then pythonSet.${item} else null
                else if lib.isDerivation item then
                  item
                else
                  null;
            in
            if pkg == null then
              [ ]
            else
              let
                key =
                  if builtins.isString item then
                    item
                  else
                    (pkg.pname or pkg.name);
                deps = pkg.dependencies or { };
                next =
                  if builtins.isAttrs deps then
                    builtins.attrNames deps
                  else if builtins.isList deps then
                    deps
                  else
                    [ ];
                seen' = seen // { "${key}" = true; };
              in
              if builtins.hasAttr key seen then
                [ ]
              else
                [ pkg ] ++ builtins.concatLists (map (dep: recurse seen' dep) next);
        in
        lib.unique (builtins.concatLists (map (dep: recurse { } dep) rootDeps));

      mkWrappedPython =
        system: enableCuda: name:
        let
          pkgs = pkgsFor system;
          pythonSet = mkPackagePythonSet system enableCuda;
          rootPkg = pythonSet."chatterbox-tts";
          runtimeDeps = resolveRuntimeDeps pythonSet (builtins.attrNames rootPkg.dependencies);
          extraPythonRuntimeDeps = [
            pkgs.python312Packages.mpmath
          ];
          pythonPath = lib.concatStringsSep ":" (
            map (drv: "${drv}/${pkgs.python312.sitePackages}") ([ rootPkg ] ++ runtimeDeps ++ extraPythonRuntimeDeps)
          );
        in
        pkgs.symlinkJoin {
          inherit name;
          paths = [
            pkgs.python312
            pkgs.ffmpeg
            pkgs.libsndfile
            pkgs.cacert
          ];
          nativeBuildInputs = [ pkgs.makeWrapper ];
          postBuild = ''
            wrapProgram $out/bin/python \
              --prefix LD_LIBRARY_PATH : "${lib.makeLibraryPath [ pkgs.libsndfile ]}" \
              --set NIX_SSL_CERT_FILE "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt" \
              --set SSL_CERT_FILE "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt" \
              --set PYTHONNOUSERSITE 1 \
              --set PYTHONPATH "${pythonPath}"

            if [ -e "$out/bin/python3" ]; then
              wrapProgram $out/bin/python3 \
                --prefix LD_LIBRARY_PATH : "${lib.makeLibraryPath [ pkgs.libsndfile ]}" \
                --set NIX_SSL_CERT_FILE "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt" \
                --set SSL_CERT_FILE "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt" \
                --set PYTHONNOUSERSITE 1 \
                --set PYTHONPATH "${pythonPath}"
            fi
          '';
        };

      mkSmokeCheck =
        system: name: pythonEnv: code:
        let
          pkgs = pkgsFor system;
        in
        pkgs.runCommand name
          {
            nativeBuildInputs = [ pythonEnv ];
          }
          ''
            export HOME="$TMPDIR"
            ${pythonEnv}/bin/python - <<'PY'
            ${code}
            PY
            touch "$out"
          '';

    in
    {
      packages = forEachSystem (
        system:
        let
          pkgs = pkgsFor system;
          cpuPythonSet = mkPackagePythonSet system false;
          cudaPythonSet = mkPackagePythonSet system true;
          chatterboxPython = mkWrappedPython system false "chatterbox-python";
          chatterboxCudaPython = mkWrappedPython system true "chatterbox-cuda-python";
          chatterboxGradioCuda = pkgs.writeShellApplication {
            name = "chatterbox-gradio-cuda";
            runtimeInputs = [
              chatterboxCudaPython
            ];
            text = ''
              exec ${chatterboxCudaPython}/bin/python ${chatterboxSrc}/gradio_tts_app.py "$@"
            '';
          };
        in
        {
          default = cpuPythonSet."chatterbox-tts";
          chatterbox = cpuPythonSet."chatterbox-tts";
          chatterbox-python = chatterboxPython;
          chatterbox-cuda = cudaPythonSet."chatterbox-tts";
          chatterbox-cuda-python = chatterboxCudaPython;
          chatterbox-gradio-cuda = chatterboxGradioCuda;
        }
      );

      checks = forEachSystem (
        system:
        let
          pkgs = pkgsFor system;
          chatterboxPython = self.packages.${system}.chatterbox-python;
          chatterboxCudaPython = self.packages.${system}.chatterbox-cuda-python;
        in
        {
          chatterbox-import = mkSmokeCheck system "chatterbox-import-check" chatterboxPython ''
            import chatterbox
            import torch
            import torchaudio
            print(chatterbox.__file__)
            print(torch.__version__)
            print(torchaudio.__version__)
          '';

          chatterbox-cuda-import = mkSmokeCheck system "chatterbox-cuda-import-check" chatterboxCudaPython ''
            import chatterbox
            import torch
            import torchaudio
            assert torch.version.cuda is not None, "Torch was not built with CUDA support"
            print(chatterbox.__file__)
            print(torch.__version__)
            print(torch.version.cuda)
            print(torch.backends.cuda.is_built())
            print(torchaudio.__version__)
          '';

          chatterbox-gradio-import = mkSmokeCheck system "chatterbox-gradio-import-check" chatterboxCudaPython ''
            import importlib.util
            import pathlib

            script_path = pathlib.Path("${chatterboxSrc}/gradio_tts_app.py")
            spec = importlib.util.spec_from_file_location("gradio_tts_app", script_path)
            module = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(module)

            assert hasattr(module, "demo")
            assert module.DEVICE in {"cpu", "cuda"}
            print(module.DEVICE)
          '';

          chatterbox-gradio-generate = mkSmokeCheck system "chatterbox-gradio-generate-check" chatterboxCudaPython ''
            import importlib.util
            import pathlib
            import torch

            script_path = pathlib.Path("${chatterboxSrc}/gradio_tts_app.py")
            spec = importlib.util.spec_from_file_location("gradio_tts_app", script_path)
            module = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(module)

            class FakeModel:
                sr = 24000

                def generate(self, text, **kwargs):
                    assert text == "Hello from chatterbox."
                    assert kwargs["audio_prompt_path"] is None
                    return torch.zeros(1, 64)

            sr, wav = module.generate(
                FakeModel(),
                "Hello from chatterbox.",
                None,
                0.5,
                0.8,
                123,
                0.5,
                0.05,
                1.0,
                1.2,
            )

            assert sr == 24000
            assert wav.shape == (64,)
            assert float(wav.sum()) == 0.0
            print(sr, wav.shape)
          '';

          chatterbox-core-smoke = mkSmokeCheck system "chatterbox-core-smoke-check" chatterboxCudaPython ''
            from chatterbox.tts import punc_norm

            normalized = punc_norm("hello from chatterbox")
            assert normalized == "Hello from chatterbox."
            print(normalized)
          '';
        }
      );
    };
}
