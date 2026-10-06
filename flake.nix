{
  description = "Focus Point: Lightroom Classic plugin + Rust CLI showing the AF point of Sony a7 IV photos";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
    }:
    flake-utils.lib.eachSystem
      [
        "aarch64-darwin"
        "x86_64-darwin"
        "x86_64-linux"
        "aarch64-linux"
      ]
      (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          lib = pkgs.lib;

          # Only the files the Rust build needs, so editing the Lua plugin does
          # not rebuild the CLI.
          cliSrc = lib.fileset.toSource {
            root = ./.;
            fileset = lib.fileset.unions [
              ./Cargo.toml
              ./Cargo.lock
              ./src
              ./tests
            ];
          };

          focuspoint = pkgs.rustPlatform.buildRustPackage {
            pname = "focuspoint";
            version = (lib.importTOML ./Cargo.toml).package.version;
            src = cliSrc;
            cargoLock.lockFile = ./Cargo.lock;
            meta = {
              description = "Read and render the autofocus point of Sony a7 IV photos";
              mainProgram = "focuspoint";
            };
          };

          plugin = pkgs.runCommand "focuspoint-lrplugin" { } ''
            dest=$out/focuspoint.lrplugin
            mkdir -p "$dest"
            cp -R ${./plugin/focuspoint.lrplugin}/. "$dest/"
            chmod -R u+w "$dest"
            rm -f "$dest/.keep"
            mkdir -p "$dest/bin"
            cp ${focuspoint}/bin/focuspoint "$dest/bin/focuspoint"
          '';

          install = pkgs.writeShellApplication {
            name = "focuspoint-install";
            text = ''
              src="${plugin}/focuspoint.lrplugin"
              modules="$HOME/Library/Application Support/Adobe/Lightroom/Modules"
              dest="$modules/focuspoint.lrplugin"
              mkdir -p "$modules"
              if [ -e "$dest" ]; then
                echo "Removing old plugin: $dest"
                rm -rf "$dest"
              fi
              cp -R "$src" "$dest"
              chmod -R u+w "$dest"
              chmod u+x "$dest/bin/focuspoint"
              echo "Installed Focus Point plugin:"
              echo "  from $src"
              echo "  to   $dest"
              "$dest/bin/focuspoint" --version || true
              echo "Restart Lightroom Classic (or use File > Plug-in Manager > Reload) to load it."
            '';
          };
        in
        {
          packages = {
            default = focuspoint;
            inherit focuspoint plugin;
          };

          apps = {
            install = {
              type = "app";
              program = "${install}/bin/focuspoint-install";
              meta.description = "Copy the plugin bundle into Lightroom Classic's Modules folder";
            };
            default = {
              type = "app";
              program = "${focuspoint}/bin/focuspoint";
              meta.description = "focuspoint CLI";
            };
          };

          checks = {
            inherit focuspoint plugin;
          };

          devShells.default = pkgs.mkShell {
            packages = [
              pkgs.cargo
              pkgs.rustc
              pkgs.clippy
              pkgs.rustfmt
              pkgs.rust-analyzer
              pkgs.exiftool
              pkgs.lua5_1
            ];
            RUST_SRC_PATH = "${pkgs.rustPlatform.rustLibSrc}";
          };

          formatter = pkgs.nixfmt;
        }
      );
}
