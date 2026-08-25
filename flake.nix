{
  description = "NixOS module for snapraid-btrfs.";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    flake-utils.url = "github:numtide/flake-utils";
    # snapraid-btrfs script. We use the D34DC3N73R fork rather than upstream
    # automorphism88/snapraid-btrfs because the latter is still incompatible with
    # snapper 0.11.x. The breakage is that snapper changed the `get-config`
    # output separator from the ASCII pipe `|` to the box-drawing character `│`
    # (U+2502); upstream's parser only strips `|`
    # (`sed -e 's/^SUBVOLUME[ ]*| //'`), so it fails to read SUBVOLUME and
    # reports "No snapper configs found". The fork fixes it with
    # `s/^SUBVOLUME[ ]*[|│] //`. Tracked upstream in issue #23. Once that fix
    # lands in automorphism88/master we can switch back and drop the fork
    # (https://github.com/automorphism88/snapraid-btrfs/issues/23).
    snapraid-btrfs-src = {
      url = "github:D34DC3N73R/snapraid-btrfs";
      flake = false;
    };
    # Upstream snapraid-btrfs-runner (Python driver).
    snapraid-btrfs-runner-src = {
      url = "github:fmoledina/snapraid-btrfs-runner";
      flake = false;
    };
  };

  outputs = {
    self,
    nixpkgs,
    flake-utils,
    snapraid-btrfs-src,
    snapraid-btrfs-runner-src,
  }:
    {
      overlays.default = final: prev: rec {
        make-snapraid-btrfs-runner = configFile:
          final.callPackage ./pkgs/snapraid-btrfs-runner.nix {
            snapraidBtrfsRunnerSrc = snapraid-btrfs-runner-src;
            configFile = configFile;
          };
        snapraid-btrfs =
          final.callPackage ./pkgs/snapraid-btrfs.nix
          {snapraidBtrfsSrc = snapraid-btrfs-src;};
      };
      # The module reads `pkgs.snapraid-btrfs` and `pkgs.make-snapraid-btrfs-runner`
      # (built by `overlays.default`). We apply that overlay here so importing
      # `nixosModules.default` is enough — consumers don't have to wire up the
      # overlay themselves.
      nixosModules = rec {
        snapraid-btrfs = [
          (import ./modules/snapraid-btrfs.nix)
          {nixpkgs.overlays = [self.overlays.default];}
        ];
        default = snapraid-btrfs;
      };
    }
    // flake-utils.lib.eachDefaultSystem (
      system: let
        pkgs = import nixpkgs {
          inherit system;
          overlays = [self.overlays.default];
        };
      in {
        packages = rec {
          snapraid-btrfs = pkgs.snapraid-btrfs;
          default = snapraid-btrfs;
        };

        checks.snapraid-btrfs-vm = import ./tests/vm.nix {inherit self nixpkgs;};
      }
    );
}
