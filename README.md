# nixos-snapraid-btrfs

A self-contained NixOS module that wires up
[snapraid-btrfs](https://github.com/automorphism88/snapraid-btrfs) and
[snapraid-btrfs-runner](https://github.com/fmoledina/snapraid-btrfs-runner)
for a Btrfs-based SnapRAID setup, including snapper snapshots and a
hardened daily sync service.

## Usage

Add this flake as an input and import the module:

```nix
{
  inputs.snapraid-btrfs.url = "github:damianfral/nixos-snapraid-btrfs";

  outputs = {nixpkgs, snapraid-btrfs, ...}: {
    nixosConfigurations.host = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        snapraid-btrfs.nixosModules.default

        {
          services.snapraid-btrfs = {
            dataDisks = {
              data1 = "/mnt/data1";
              data2 = "/mnt/data2";
            };
            # Content files must live in a subvolume SEPARATE from each data
            # subvolume (snapraid-btrfs rejects content inside a data
            # subvolume), and the two content files must be on different disks.
            contentFiles = [
              "/mnt/content1/snapraid.content"
              "/mnt/content2/snapraid.content"
            ];
            parityFiles = ["/mnt/parity/snapraid.parity"];

            # one snapper config per data disk is typical
            snapperConfigs = {
              data1 = {
                SUBVOLUME = "/mnt/data1";
                ALLOW_GROUPS = ["wheel"];
                SYNC_ACL = true;
              };
              data2 = {
                SUBVOLUME = "/mnt/data2";
                ALLOW_GROUPS = ["wheel"];
                SYNC_ACL = true;
              };
            };

            # run the daily sync and email reports
            runner.config.email = {
              from = "snapraid@example.com";
              to = "you@example.com";
            };
          };
        }
      ];
    };
  };
}
```

## Options

- **`services.snapraid-btrfs.dataDisks`** (`attrsOf str`, default `{}`)
  SnapRAID data disks as an attrset of name → mount path.
  
- **`services.snapraid-btrfs.contentFiles`** (`listOf str`, default `[]`)
  SnapRAID content file paths.
  
- **`services.snapraid-btrfs.parityFiles`** (`listOf str`, default `[]`)
  SnapRAID parity file paths.
  
- **`services.snapraid-btrfs.exclude`** (`listOf str`, default: sensible defaults)
  Exclusion patterns passed to SnapRAID.
  
- **`services.snapraid-btrfs.syncAt`** (`str`, default `"22:00"`)
  systemd calendar expression for the daily sync.
  
- **`services.snapraid-btrfs.snapperConfigs`** (`attrsOf anything`, default `{}`)
  Snapper configurations to create (one per data disk).
  
- **`services.snapraid-btrfs.runner.config`** (`attrsOf (attrsOf str)`,
default: upstream defaults)
  `snapraid-btrfs-runner` INI configuration; merged on top of the generated
  defaults.
  

The module relies on the `snapraid-btrfs` and `snapraid-btrfs-runner`
packages, which are built by this flake's `overlays.default`. Importing
`nixosModules.default` applies that overlay automatically, so no extra wiring
is needed. For standalone use, the same packages are also exposed via
`packages.<system>.*` (and `make-snapraid-btrfs-runner` via the overlay).

## Required Btrfs layout

`snapraid-btrfs` has two hard constraints that this module relies on you to
satisfy at the filesystem level:

- **Content files must live in a subvolume separate from the data subvolume.**
  A content file placed directly inside a data disk's subvolume is rejected
  (`content files must be in separate subvolume`).
- **The two (or more) `contentFiles` must be on different disks.**

A working layout therefore gives each data disk two subvolumes: a `data`
subvolume (snapshotted by snapper) and a sibling `content` subvolume (not
snapshotted), e.g.:

```
/mnt/data1      (subvolume: data)     <- dataDisks.data1
/mnt/content1   (subvolume: content)  <- contentFiles[0]
/mnt/data2      (subvolume: data)     <- dataDisks.data2
/mnt/content2   (subvolume: content)  <- contentFiles[1]
/mnt/parity     (subvolume)           <- parityFiles
```

The module **auto-creates** the `<SUBVOLUME>/.snapshots` subvolume for every
entry in `snapperConfigs` (idempotently: it skips subvolumes that are not yet
mounted and those that already have one), so you do not need to create it by
hand. You are responsible for mounting the disks/subvolumes themselves (for
example via `fileSystems` or disko, see below).

### Example with disko

If you provision disks with [disko](https://github.com/nix-community/disko),
declare the subvolumes (including `.snapshots`) there. The schema below matches
recent disko versions, adapt it to the disko version you use:

```nix
{
  disko.devices = {
    disk.data1 = {
      device = "/dev/sda";
      content = {
        type = "gpt";
        partitions.btrfs = {
          size = "100%";
          content = {
            type = "btrfs";
            subvolumes = {
              "data1" = { mountpoint = "/mnt/data1"; };
              "data1/.snapshots" = { mountpoint = null; };
              "content1" = { mountpoint = "/mnt/content1"; };
            };
          };
        };
      };
    };
    # repeat for data2 (/mnt/data2, /mnt/data2/.snapshots, /mnt/content2)
    # and a parity disk (/mnt/parity)
  };
}
```

## Notes

- The parity directory is automatically created with chattr +C (NOCOW) to
  avoid Btrfs running out of free space while updating large parity
  files when the parity filesystem is nearly full.

- The `.snapshots` subvolume for each `snapperConfigs` entry is created
  by the `snapraid-btrfs-mksnapshots` service (idempotent; safe to run
  repeatedly).

- The module asserts that `dataDisks` and `parityFiles` are non-empty
  and that `contentFiles` has at least `parityFiles + 1` entries; otherwise
  the configuration fails fast with a clear message.

- The `snapraid-btrfs-sync` service runs in a locked-down systemd sandbox.
  It permits `AF_UNIX` (for snapper/snapraid) and `AF_INET`/`AF_INET6`
  (so the runner can send SMTP email reports); override
  `systemd.services.snapraid-btrfs-sync.serviceConfig` if you need a
  different policy.

## Tests

A NixOS VM test lives in `tests/vm.nix` and is wired as a flake check
(`checks.x86_64-linux.snapraid-btrfs-vm`). It boots a machine with the
module enabled, then:

- Asserts the `snapraid-btrfs`, `snapraid-btrfs-runner` and `snapraid`
  binaries are present and runnable.
    
- Asserts the generated `/etc/snapraid.conf` (from `services.snapraid`)
  exists and the `snapraid-btrfs-sync` and `snapraid-btrfs-mksnapshots`
  systemd services are defined, then verifies the `.snapshots` subvolumes
  get created.
    
- Creates three loop-backed Btrfs images (two data disks, one parity disk),
  mounts them, and runs a real `snapraid sync` using the generated config.

- Runs the full `snapraid-btrfs-runner` end-to-end (snapper snapshots +
  snapraid sync).  This requires KVM and a few gigabytes of free disk for
  the VM closure.
