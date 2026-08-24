{
  pkgs,
  snapraidBtrfsSrc,
  symlinkJoin,
  writeScriptBin,
  makeWrapper,
  coreutils,
  gnugrep,
  gawk,
  gnused,
  snapraid,
  snapper,
}: let
  name = "snapraid-btrfs";
  deps = [coreutils gnugrep gawk gnused snapraid snapper];
  script =
    (
      writeScriptBin name
      # NOTE: Forked version from D34DC3N73R to fix snapper 0.11.1
      #       compatibility. Sourced from the `snapraid-btrfs-src` flake input
      #       (see flake.nix); the module injects it via an overlay so this
      #       package's `snapraidBtrfsSrc` default resolves. Override
      #       `snapraidBtrfsSrc` to use a different checkout.
      (builtins.readFile (snapraidBtrfsSrc + "/snapraid-btrfs"))
    )
    .overrideAttrs (old: {
      buildCommand = "${old.buildCommand}\n patchShebangs $out";
    });
in
  symlinkJoin {
    inherit name;
    paths = [script] ++ deps;
    buildInputs = [makeWrapper];
    postBuild = "wrapProgram $out/bin/${name} --set PATH $out/bin";
  }
