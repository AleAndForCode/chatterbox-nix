{ pkgs }:
final: prev:
let
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
}
