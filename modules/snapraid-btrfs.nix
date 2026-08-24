{
  config,
  lib,
  pkgs,
  ...
}:
with lib; let
  cfg = config.services.snapraid-btrfs;

  defaultExclude = [
    ".snapshots/"
    "snapshots/"
    "snapshots/**"
    # Lightroom
    "**/*Previews.lrdata/**"
    "*~"
    "appdata/"
    ".DS_Store" # macOS
    "/lost+found/"
    "._*" # macOS metadata
    "/media/.state/"
    "/media/torrents/"
    "/.snapshots/"
    "*.!sync"
    "*.temp"
    "Thumbs.db" # Windows
    "*.tmp"
    "/tmp/"
    "*.unrecoverable"
  ];

  defaultRunnerConfig = {
    "snapraid-btrfs" = {
      executable = "${pkgs.snapraid-btrfs}/bin/snapraid-btrfs";
      "snapper-configs" = "";
      "snapper-configs-file" = "";
      pool = "false";
      "pool-dir" = "";
      cleanup = "true";
    };
    snapper = {
      executable = "${pkgs.snapper}/bin/snapper";
    };
    snapraid = {
      executable = "${pkgs.snapraid}/bin/snapraid";
      config = "/etc/snapraid.conf";
      deletethreshold = "100";
      touch = "false";
    };
    logging = {
      file = "";
      maxsize = "5000";
    };
    email = {
      sendon = "success, error";
      short = "false";
      subject = "[SnapRAID] Status Report:";
      from = "";
      to = "";
      maxsize = "5000";
    };
    smtp = {
      host = "localhost";
      port = "25";
      ssl = "false";
      tls = "false";
      user = "";
      password = "";
    };
    scrub = {
      enabled = "false";
      plan = "12";
      "older-than" = "10";
    };
  };

  # User-provided `runner.config` is merged on top of `defaultRunnerConfig`,
  # so partial overrides (e.g. just the email section) don't wipe the defaults.
  finalRunnerConfig = lib.recursiveUpdate defaultRunnerConfig cfg.runner.config;

  runnerConfigFile = pkgs.writeTextFile {
    name = "snapraid-btrfs-runner.conf";
    text = generators.toINI {} finalRunnerConfig;
  };

  runnerPkg = pkgs.make-snapraid-btrfs-runner runnerConfigFile;

  snapperSubvolumes =
    lib.mapAttrsToList (_: c: c.SUBVOLUME)
    (lib.filterAttrs (_: c: c ? SUBVOLUME) cfg.snapperConfigs);

  mksnapshotsScript = pkgs.writeScript "snapraid-btrfs-mksnapshots" ''
    #!${pkgs.runtimeShell}
    set -e
    for sub in ${lib.escapeShellArgs snapperSubvolumes}; do
      if [ -d "$sub" ] && [ ! -e "$sub/.snapshots" ]; then
        ${pkgs.btrfs-progs}/bin/btrfs subvolume create "$sub/.snapshots"
        chmod 750 "$sub/.snapshots"
      fi
    done
  '';

  parityDir = lib.optionalString (cfg.parityFiles != []) (dirOf (head cfg.parityFiles));
in {
  options.services.snapraid-btrfs = {
    dataDisks = mkOption {
      type = types.attrsOf types.str;
      default = {};
      example = {data = "/mnt/data";};
      description = "SnapRAID data disks as an attrset of name -> mount path.";
    };

    contentFiles = mkOption {
      type = types.listOf types.str;
      default = [];
      example = ["/mnt/data/snapraid.content"];
      description = "Paths to SnapRAID content files.";
    };

    parityFiles = mkOption {
      type = types.listOf types.str;
      default = [];
      example = ["/mnt/parity/snapraid.parity"];
      description = "Paths to SnapRAID parity files.";
    };

    exclude = mkOption {
      type = types.listOf types.str;
      default = defaultExclude;
      description = "Exclusion patterns passed to SnapRAID.";
    };

    syncAt = mkOption {
      type = types.str;
      default = "22:00";
      description = "systemd calendar expression for the daily runner sync.";
    };

    snapperConfigs = mkOption {
      type = types.attrsOf types.anything;
      default = {};
      example = {
        data = {
          SUBVOLUME = "/mnt/data";
          ALLOW_GROUPS = ["wheel"];
          SYNC_ACL = true;
        };
      };
      description = "Snapper configurations to create (typically one per data disk).";
    };

    runner = {
      config = mkOption {
        type = types.attrsOf (types.attrsOf types.str);
        default = {};
        example = {
          email = {
            from = "snapraid@example.com";
            to = "you@example.com";
          };
        };
        description = ''
          Partial overrides merged on top of the generated defaults for the
          snapraid-btrfs-runner INI configuration (see upstream for all keys).
          The defaults already point the executables at the packaged binaries.
        '';
      };
    };
  };

  config = {
    assertions = [
      {
        assertion = cfg.dataDisks != {};
        message = "services.snapraid-btrfs.dataDisks must not be empty.";
      }
      {
        assertion = cfg.parityFiles != [];
        message = "services.snapraid-btrfs.parityFiles must not be empty.";
      }
      {
        assertion = lib.length cfg.contentFiles >= lib.length cfg.parityFiles + 1;
        message = "services.snapraid-btrfs.contentFiles must contain at least (parityFiles + 1) entries.";
      }
    ];

    environment.systemPackages = with pkgs; [
      snapraid-btrfs
      runnerPkg
    ];

    services.snapraid = {
      enable = true;
      sync.interval = "";
      scrub.interval = "";
      dataDisks = cfg.dataDisks;
      contentFiles = cfg.contentFiles;
      parityFiles = cfg.parityFiles;
      exclude = cfg.exclude;
    };

    services.snapper.configs = cfg.snapperConfigs;

    systemd.tmpfiles.rules = mkIf (cfg.parityFiles != []) [
      "d ${parityDir} 0755 root root -"
    ];

    systemd.services.snapraid-parity-nocow = mkIf (cfg.parityFiles != []) {
      description = "Set SnapRAID parity directory to NOCOW";
      wantedBy = ["local-fs.target"];
      after = ["local-fs.target"];

      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${pkgs.e2fsprogs}/bin/chattr +C ${parityDir}";
        RemainAfterExit = true;
      };
    };

    # Ensures each snapper data subvolume has a .snapshots subvolume. The
    # NixOS snapper module writes the config files but does not create the
    # .snapshots subvolume that snapraid-btrfs requires. Idempotent: it skips
    # subvolumes that are not yet mounted and those that already have one.
    systemd.services.snapraid-btrfs-mksnapshots = mkIf (cfg.snapperConfigs != {}) {
      description = "Create snapper .snapshots subvolumes for snapraid-btrfs data disks";
      wantedBy = ["multi-user.target"];
      after = ["local-fs.target"];
      before = ["snapraid-btrfs-sync.service"];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${mksnapshotsScript}";
      };
    };

    systemd.services.snapraid-btrfs-sync = {
      description = "Run the snapraid-btrfs sync with the runner";
      startAt = [cfg.syncAt];
      requires = ["snapraid-btrfs-mksnapshots.service"];
      after = ["snapraid-btrfs-mksnapshots.service"];
      serviceConfig = {
        Type = "oneshot";
        User = "root";
        Group = "root";
        ExecStart = "${runnerPkg}/bin/snapraid-btrfs-runner";
        Nice = 19;
        IOSchedulingPriority = 7;
        IOSchedulingClass = "idle";
        CPUSchedulingPolicy = "batch";
        LockPersonality = true;
        MemoryDenyWriteExecute = true;
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectClock = true;
        ProtectControlGroups = true;
        ProtectHostname = true;
        ProtectKernelLogs = true;
        ProtectKernelModules = true;
        ProtectKernelTunables = true;
        # AF_INET/AF_INET6 are allowed so the runner can send SMTP email
        # reports; AF_UNIX covers snapper/snapraid local communication.
        RestrictAddressFamilies = "AF_UNIX AF_INET AF_INET6";
        RestrictNamespaces = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        SystemCallArchitectures = "native";
        SystemCallFilter = "@system-service";
        SystemCallErrorNumber = "EPERM";
        CapabilityBoundingSet = "";
        ProtectSystem = "strict";
        ProtectHome = "read-only";
        ReadOnlyPaths = ["/etc/snapraid.conf" "/etc/snapper"];
        ReadWritePaths =
          # sync requires access to directories containing content files
          # to remove them if they are stale
          let
            contentDirs = builtins.map builtins.dirOf cfg.contentFiles;
          in
            pkgs.lib.unique (
              builtins.attrValues cfg.dataDisks ++ cfg.parityFiles ++ contentDirs
            );
      };
    };
  };
}
