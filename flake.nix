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
      in
      {
        packages = {
          gitclone = pkgs.stdenv.mkDerivation {
            pname = "gitclone";
            version = "0.1.0";
            src = ./.;

            nativeBuildInputs = [ pkgs.zig ];

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
            src = ./.;

            nativeBuildInputs = [ pkgs.zig ];

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

          default = self.packages.${system}.nix-zsh-env;
        };

        apps = {
          nix-zsh-env = {
            type = "app";
            program = "${self.packages.${system}.nix-zsh-env}/bin/nix-zsh-env";
          };
          default = self.apps.${system}.nix-zsh-env;
        };
      }
    );
}
