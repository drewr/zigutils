{
  description = "Zig utilities including nix-zsh-env";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};

        # Zig dev build from https://ziglang.org/download/, pinned with
        # checksums for reproducible builds. Bundled as a virtual package
        # below so we don't depend on whatever nixpkgs happens to pin.
        zigVersion = "0.18.0-dev.610+720939f8c";
        zigBuilds = {
          aarch64-darwin = {
            arch = "aarch64-macos";
            sha256 = "sha256-aqLCw8L+jVQkMMBqmQuMsKKYjd2RhW4djvKywqDDe78=";
          };
          x86_64-darwin = {
            arch = "x86_64-macos";
            sha256 = "sha256-5WLJqIoMqWdzLj/INcV7lFizLNPK8BKaElEfx7T6zlc=";
          };
          x86_64-linux = {
            arch = "x86_64-linux";
            sha256 = "sha256-HuoVuR1pkLKtrjMEsJZbdbK6Fgdqt64pxjqzEDxVFaQ=";
          };
          aarch64-linux = {
            arch = "aarch64-linux";
            sha256 = "sha256-qS442h8vep0cgSAJ4w7b/rmet3I1fbIVgTmCxVdxj5U=";
          };
        };
        zigCfg = zigBuilds.${system} or
          (throw "zig-${zigVersion}: unsupported system '${system}'");

        # A virtual package installing the zig tarball from ziglang.org.
        zig-dev = pkgs.stdenv.mkDerivation {
          pname = "zig";
          version = zigVersion;

          src = pkgs.fetchurl {
            url = "https://ziglang.org/builds/zig-${zigCfg.arch}-${zigVersion}.tar.xz";
            sha256 = zigCfg.sha256;
          };

          dontConfigure = true;
          dontBuild = true;

          installPhase = ''
            mkdir -p $out
            cp -r ./* $out/
            chmod +x $out/zig
            mkdir -p $out/bin
            ln -s $out/zig $out/bin/zig
          '';

          meta = {
            description = "Zig ${zigVersion} developer build from ziglang.org";
            license = pkgs.lib.licenses.mit;
            platforms = pkgs.lib.platforms.all;
          };
        };

        # Filter the copied source to only what zig needs. Including stray
        # directories (e.g. .git, .zig-cache, zig-out, result, tmp) trips a
        # Zig cache bug (`file_hash FileNotFound`) when building in the Nix
        # sandbox on macOS.
        filteredSrc = pkgs.lib.cleanSourceWith {
          src = ./.;
          filter = path: type:
            let base = baseNameOf path; in
            base != ".git" &&
            base != ".zig-cache" &&
            base != "zig-out" &&
            base != "result" &&
            base != ".claude" &&
            base != "tmp";
        };
      in
      {
        packages = {
          inherit zig-dev;

          gitclone = pkgs.stdenv.mkDerivation {
            pname = "gitclone";
            version = "0.1.0";
            src = filteredSrc;

            nativeBuildInputs = [ zig-dev ];

            buildPhase = ''
              export HOME=$TMPDIR
              zig build -Doptimize=ReleaseSafe
            '';

            installPhase = ''
              mkdir -p $out/bin
              cp zig-out/bin/gitclone $out/bin/
            '';

            meta = {
              description = "Clone git repositories";
              license = pkgs.lib.licenses.mit;
              platforms = pkgs.lib.platforms.all;
            };
          };

          nix-zsh-env = pkgs.stdenv.mkDerivation {
            pname = "nix-zsh-env";
            version = "0.1.0";
            src = filteredSrc;

            nativeBuildInputs = [ zig-dev ];

            buildPhase = ''
              export HOME=$TMPDIR
              zig build -Doptimize=ReleaseSafe
            '';

            installPhase = ''
              mkdir -p $out/bin
              cp zig-out/bin/nix-zsh-env $out/bin/
            '';

            meta = {
              description = "Display nix-shell packages for zsh prompt";
              license = pkgs.lib.licenses.mit;
              platforms = pkgs.lib.platforms.all;
            };
          };

          tmphttp = pkgs.stdenv.mkDerivation {
            pname = "tmphttp";
            version = "0.1.0";
            src = filteredSrc;

            nativeBuildInputs = [ zig-dev ];

            buildPhase = ''
              export HOME=$TMPDIR
              zig build -Doptimize=ReleaseSafe
            '';

            installPhase = ''
              mkdir -p $out/bin
              cp zig-out/bin/tmphttp $out/bin/
            '';

            meta = {
              description = "Serve a temporary directory over HTTP with a live TUI";
              license = pkgs.lib.licenses.mit;
              platforms = pkgs.lib.platforms.all;
            };
          };

          default = pkgs.symlinkJoin {
            name = "zigutils";
            paths = [
              self.packages.${system}.gitclone
              self.packages.${system}.nix-zsh-env
              self.packages.${system}.tmphttp
            ];
          };
        };

        devShells.default = pkgs.mkShell {
          name = "zigutils";
          packages = [ zig-dev ];
        };

        apps = {
          gitclone = {
            type = "app";
            program = "${self.packages.${system}.gitclone}/bin/gitclone";
          };
          nix-zsh-env = {
            type = "app";
            program = "${self.packages.${system}.nix-zsh-env}/bin/nix-zsh-env";
          };
          tmphttp = {
            type = "app";
            program = "${self.packages.${system}.tmphttp}/bin/tmphttp";
          };
          default = self.apps.${system}.gitclone;
        };
      }
    );
}
