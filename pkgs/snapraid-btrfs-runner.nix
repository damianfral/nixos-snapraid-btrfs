{
  pkgs,
  configFile ? null,
  symlinkJoin,
  writeScriptBin,
  makeWrapper,
  lib,
  python311,
  snapraid,
  snapraid-btrfs,
  snapper,
  snapraidBtrfsRunnerSrc,
}: let
  name = "snapraid-btrfs-runner";
  deps = [python311 snapraid snapraid-btrfs snapper];
  script =
    (
      writeScriptBin name
      # Sourced from the `snapraid-btrfs-runner-src` flake input (see flake.nix);
      # the module injects it via an overlay so this package's
      # `snapraidBtrfsRunnerSrc` default resolves. Override `snapraidBtrfsRunnerSrc`
      # to use a different checkout.
      (builtins.readFile (snapraidBtrfsRunnerSrc + "/snapraid-btrfs-runner.py"))
    )
    .overrideAttrs (old: {
      buildCommand = "${old.buildCommand}\n patchShebangs $out";
    });
  wrapFlag =
    lib.optionalString (configFile != null) "--add-flags '-c ${configFile}'";
in
  symlinkJoin {
    inherit name;
    paths = [script] ++ deps;
    buildInputs = [makeWrapper python311];
    postBuild = "wrapProgram $out/bin/${name} ${wrapFlag} --set PATH $out/bin";
  }
