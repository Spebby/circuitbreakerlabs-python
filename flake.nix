{
  description = "Circuit Breaker Labs Python client development environment";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";

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
      inputs = {
        pyproject-nix.follows = "pyproject-nix";
        uv2nix.follows = "uv2nix";
        nixpkgs.follows = "nixpkgs";
      };
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
      pyproject-nix,
      uv2nix,
      pyproject-build-systems,
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        inherit (nixpkgs) lib;

        workspace = uv2nix.lib.workspace.loadWorkspace { workspaceRoot = ./.; };
        pyprojectOverlay = workspace.mkPyprojectOverlay { sourcePreference = "wheel"; };

        mkCblLibForPython =
          callPackage: python:
          let
            pythonSet = (callPackage pyproject-nix.build.packages { inherit python; }).overrideScope (
              lib.composeManyExtensions [
                pyproject-build-systems.overlays.wheel
                pyprojectOverlay
              ]
            );
            base = pythonSet.circuit-breaker-labs;
            dependencyNames = builtins.attrNames (base.dependencies or { });
          in
          base.overrideAttrs (old: {
            propagatedBuildInputs =
              (old.propagatedBuildInputs or [ ])
              ++ map (name: pythonSet.${name}) dependencyNames
              ++ lib.concatMap (name: pythonSet.${name}.requiredPythonModules or [ ]) dependencyNames;
          });

        python = lib.head (
          pyproject-nix.lib.util.filterPythonInterpreters {
            inherit (workspace) requires-python;
            inherit (pkgs) pythonInterpreters;
          }
        );

        cblLib = mkCblLibForPython pkgs.callPackage python;

        build = with pkgs; [
          uv
          openapi-python-client
        ];

        postProcessing = with pkgs; [
          ruff
          prettier
        ];
      in
      {
        packages.default = cblLib;

        overlays.default = _: prev: {
          pythonPackagesExtensions = (prev.pythonPackagesExtensions or [ ]) ++ [
            (pyfinal: _: {
              cblLib =
                let
                  base = mkCblLibForPython pyfinal.callPackage pyfinal.python;
                  dependencyNames = builtins.attrNames (base.dependencies or { });
                  directDeps = map (name: pyfinal.${name}) dependencyNames;
                  recursiveDeps = lib.concatMap (drv: drv.requiredPythonModules or [ ]) directDeps;
                in
                base.overrideAttrs (old: {
                  propagatedBuildInputs = lib.unique (
                    (old.propagatedBuildInputs or [ ]) ++ directDeps ++ recursiveDeps
                  );
                  passthru = (old.passthru or { }) // {
                    pythonModule = pyfinal.python;
                    requiredPythonModules = lib.unique ([ pyfinal.python ] ++ directDeps ++ recursiveDeps);
                  };
                });
            })
          ];
        };

        devShells.default = pkgs.mkShell {
          LD_LIBRARY_PATH = lib.makeLibraryPath [ pkgs.stdenv.cc.cc ];

          buildInputs =
            with pkgs;
            [
              mypy
              curl
              jq
            ]
            ++ build
            ++ postProcessing;
        };

        apps.generate =
          let
            generateScript = pkgs.writeShellApplication {
              name = "generate";
              runtimeInputs = build ++ postProcessing;
              text = ''
                URL="https://api.circuitbreakerlabs.ai/v1/openapi.json"
                OPENAPI_FILE="openapi.json"

                echo "Using openapi-python-client version: $(openapi-python-client --version)"
                echo "Using config file at: $PWD/config.yaml"
                echo "Using additional templates from: $PWD/templates"
                echo "Downloading from $URL"

                curl -L -sS "$URL" | jq > "$OPENAPI_FILE"

                openapi-python-client generate --path "$OPENAPI_FILE" \
                  --output-path "$PWD" \
                  --overwrite \
                  --config "$PWD/config.yaml" \
                  --custom-template-path="$PWD/templates" \
                  --meta uv
              '';
            };
          in
          {
            type = "app";
            program = lib.getExe generateScript;
          };
      }
    );
}
