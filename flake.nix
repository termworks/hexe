{
  description = "Hexe terminal multiplexer and Zig development environment";

  nixConfig = {
    extra-substituters = [ "https://termworks.cachix.org" ];
    extra-trusted-public-keys = [
      "termworks.cachix.org-1:Ty7sSVALfD5ajbcWBIdaNHcaEx3fEmVrOo+rSzy0mvE="
    ];
  };

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs?rev=4c1018dae018162ec878d42fec712642d214fdfa";
    flake-utils.url = "github:numtide/flake-utils";
    nixgl.url = "github:nix-community/nixGL";
  };

  outputs =
    { nixpkgs, flake-utils, nixgl, ... }:
    flake-utils.lib.eachSystem [ "x86_64-linux" "aarch64-linux" ] (
      system:
      let
        overlays = [
          (final: prev: {
            xorg = prev.xorg // {
              libX11 = final.libx11;
              libxcb = final.libxcb;
              libxshmfence = final.libxshmfence;
            };
          })
        ];

        pkgs = import nixpkgs {
          inherit system overlays;
          config = {
            allowUnfree = true;
            nvidia.acceptLicense = true;
          };
        };

        lib = pkgs.lib;
        zig = pkgs.zig_0_15;
        version = builtins.head (builtins.match
          ''.*\.version = "([^"]+)";?.*''
          (builtins.readFile ./build.zig.zon));
        zigTarget = "${pkgs.stdenv.hostPlatform.parsed.cpu.name}-linux-musl";
        src = lib.fileset.toSource {
          root = ./.;
          fileset = lib.fileset.unions [
            ./build.zig
            ./build.zig.zon
            ./src
            ./scripts/vendor-ghostty.sh
            ./scripts/vendor-yazap.sh
            ./patches
            ./config
            ./share
            ./README.md
          ];
        };

        dependencies = pkgs.runCommand "hexe-dependencies" {
          nativeBuildInputs = [ zig pkgs.gitMinimal pkgs.cacert ];
          outputHashMode = "recursive";
          outputHashAlgo = "sha256";
          outputHash = "sha256-q7hVAWvWZ3d/1o6ArAs/ixmapxZSSlnT94W2CxmTZaA=";
        } ''
          export HOME="$TMPDIR/home"
          export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-cache"
          mkdir -p "$HOME"
          cp -r ${src} source
          chmod -R u+w source
          cd source
          bash scripts/vendor-ghostty.sh
          bash scripts/vendor-yazap.sh
          zig build --help -Doptimize=ReleaseFast -Dtarget=${zigTarget} > /dev/null
          find vendor -type d -name .git -prune -exec rm -rf {} +
          mkdir -p "$out"
          cp -r vendor "$out/vendor"
          cp -r "$ZIG_GLOBAL_CACHE_DIR/p" "$out/p"
        '';

        hexe = pkgs.stdenvNoCC.mkDerivation {
          pname = "hexe";
          inherit version src;
          nativeBuildInputs = [ zig pkgs.binutils ];
          dontConfigure = true;
          dontStrip = true;
          buildPhase = ''
            runHook preBuild
            export HOME="$TMPDIR/home"
            export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-cache"
            mkdir -p "$HOME" "$ZIG_GLOBAL_CACHE_DIR"
            cp -r ${dependencies}/vendor vendor
            cp -r ${dependencies}/p "$ZIG_GLOBAL_CACHE_DIR/p"
            chmod -R u+w vendor "$ZIG_GLOBAL_CACHE_DIR"
            zig build -j$NIX_BUILD_CORES \
              -Doptimize=ReleaseFast -Dstrip=true -Dtarget=${zigTarget}
            runHook postBuild
          '';
          installPhase = ''
            runHook preInstall
            install -Dm755 zig-out/bin/hexe "$out/bin/hexe"
            mkdir -p "$out/share/hexe"
            cp -r config share/runtime "$out/share/hexe/"
            runHook postInstall
          '';
          doInstallCheck = true;
          installCheckPhase = ''
            runHook preInstallCheck
            "$out/bin/hexe" --help
            "$out/bin/hexe" lua-api > "$TMPDIR/hexe-client.lua"
            test -s "$TMPDIR/hexe-client.lua"
            if readelf -l "$out/bin/hexe" | grep -q 'program interpreter'; then
              echo "error: hexe requests a dynamic loader" >&2
              exit 1
            fi
            if readelf -d "$out/bin/hexe" | grep -q NEEDED; then
              echo "error: hexe has dynamic dependencies" >&2
              exit 1
            fi
            runHook postInstallCheck
          '';
          meta = {
            description = "Terminal multiplexer with an embedded Lua runtime";
            homepage = "https://github.com/termworks/hexe";
            mainProgram = "hexe";
            platforms = [ "x86_64-linux" "aarch64-linux" ];
          };
        };

        hexeApp = {
          type = "app";
          program = "${hexe}/bin/hexe";
          meta.description = "Run Hexe";
        };

        nvidiaVersion = builtins.getEnv "NVIDIA_VERSION";
        hasNvidia = nvidiaVersion != "";

        nixglPkgs = import "${nixgl}/default.nix" ({
          inherit pkgs;
        } // pkgs.lib.optionalAttrs hasNvidia {
          inherit nvidiaVersion;
          nvidiaHash = null;
        });

        nixGLTarget =
          if hasNvidia
          then "${nixglPkgs.nixGLNvidia}/bin/nixGLNvidia-${nvidiaVersion}"
          else "${nixglPkgs.nixGLIntel}/bin/nixGLIntel";
        nixVulkanTarget =
          if hasNvidia
          then "${nixglPkgs.nixVulkanNvidia}/bin/nixVulkanNvidia-${nvidiaVersion}"
          else "${nixglPkgs.nixVulkanIntel}/bin/nixVulkanIntel";

        nixGLAlias = pkgs.runCommand "nixGL" { } ''
          mkdir -p $out/bin
          ln -s ${nixGLTarget} $out/bin/nixGL
        '';
        nixVulkanAlias = pkgs.runCommand "nixVulkan" { } ''
          mkdir -p $out/bin
          ln -s ${nixVulkanTarget} $out/bin/nixVulkan
        '';

        guiLibs = with pkgs; [
          alsa-lib
          udev
          vulkan-loader
          libxkbcommon
          wayland
          libx11
          libxcursor
          libxi
          libxrandr
        ];
      in
      {
        packages = {
          inherit hexe;
          default = hexe;
        };
        apps = {
          hexe = hexeApp;
          default = hexeApp;
        };
        checks = { inherit hexe; };

        devShells.default = pkgs.mkShell {
          packages = [
            zig
            pkgs.zls
            pkgs.git-cliff
            pkgs.clang
            pkgs.mold
            pkgs.pkg-config

            nixGLAlias
            nixVulkanAlias
            nixglPkgs.nixGLIntel
            nixglPkgs.nixVulkanIntel
          ] ++ pkgs.lib.optionals hasNvidia [
            nixglPkgs.nixGLNvidia
            nixglPkgs.nixVulkanNvidia
          ] ++ guiLibs;

          LD_LIBRARY_PATH = pkgs.lib.makeLibraryPath guiLibs;
          WGPU_VALIDATION = "0";
          WGPU_DEBUG = "0";
        };
      }
    );
}
