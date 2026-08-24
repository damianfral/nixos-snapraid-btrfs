{
  self,
  nixpkgs,
}:
nixpkgs.lib.nixos.runTest {
  name = "snapraid-btrfs";

  hostPkgs = import nixpkgs {system = "x86_64-linux";};

  nodes.machine = {
    config,
    pkgs,
    lib,
    ...
  }: {
    imports = self.nixosModules.default;

    services.snapraid-btrfs = {
      dataDisks = {
        data1 = "/mnt/data1";
        data2 = "/mnt/data2";
      };
      # Content files must live in subvolumes SEPARATE from the data
      # subvolumes (snapraid-btrfs rejects content inside a data subvolume),
      # and the two content files must be on different disks (snapraid self-test).
      contentFiles = [
        "/mnt/content1/snapraid.content"
        "/mnt/content2/snapraid.content"
      ];
      parityFiles = ["/mnt/parity/snapraid.parity"];
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
      # The VM has no MTA; don't try to send mail reports.
      runner.config.email.sendon = "";
    };

    services.dbus.enable = true;
    environment.systemPackages = [pkgs.btrfs-progs];
  };

  testScript = ''
    machine.start()
    machine.wait_for_unit("multi-user.target")

    with subtest("prepare btrfs loop disks"):
      machine.succeed("truncate -s 1G /root/disk1.img && mkfs.btrfs -f /root/disk1.img")
      machine.succeed("truncate -s 1G /root/disk2.img && mkfs.btrfs -f /root/disk2.img")
      machine.succeed("truncate -s 1G /root/disk3.img && mkfs.btrfs -f /root/disk3.img")

      # Each data disk holds a "data" subvolume (snapshotted by snapper) and a
      # "content" subvolume (separate, NOT snapshotted). snapraid-btrfs
      # requires content files to live in a subvolume separate from the data
      # subvolume, and snapraid itself requires the two content files on
      # different disks.
      machine.succeed("mkdir -p /mnt/data1-raw /mnt/data2-raw /mnt/data1 /mnt/content1 /mnt/data2 /mnt/content2 /mnt/parity")
      machine.succeed("mount -o loop /root/disk1.img /mnt/data1-raw && btrfs subvolume create /mnt/data1-raw/data && btrfs subvolume create /mnt/data1-raw/content && umount /mnt/data1-raw")
      machine.succeed("mount -o loop,subvol=data /root/disk1.img /mnt/data1")
      machine.succeed("mount -o loop,subvol=content /root/disk1.img /mnt/content1")
      machine.succeed("mount -o loop /root/disk2.img /mnt/data2-raw && btrfs subvolume create /mnt/data2-raw/data && btrfs subvolume create /mnt/data2-raw/content && umount /mnt/data2-raw")
      machine.succeed("mount -o loop,subvol=data /root/disk2.img /mnt/data2")
      machine.succeed("mount -o loop,subvol=content /root/disk2.img /mnt/content2")
      machine.succeed("mount -o loop /root/disk3.img /mnt/parity")

      # Let the module's idempotent service create the .snapshots
      # subvolumes for the data disks (the NixOS snapper module does not).
      machine.succeed("systemctl restart snapraid-btrfs-mksnapshots")
      machine.succeed("test -d /mnt/data1/.snapshots")
      machine.succeed("test -d /mnt/data2/.snapshots")

    with subtest("tools are installed and runnable"):
      machine.succeed("snapraid-btrfs --help")
      machine.succeed("snapraid-btrfs-runner --help")
      machine.succeed("snapraid --help")

    with subtest("module-generated configs exist"):
      machine.succeed("test -f /etc/snapraid.conf")
      machine.succeed("systemctl cat snapraid-btrfs-sync.service")
      machine.succeed("systemctl cat snapraid-btrfs-mksnapshots.service")
      machine.succeed("snapper list-configs | grep -q data1")
      machine.succeed("snapper list-configs | grep -q data2")

    with subtest("snapper snapshots work on the data disks"):
      machine.succeed("snapper -c data1 create -d test")
      machine.succeed("snapper -c data1 list | grep -q test")
      machine.succeed("snapper -c data2 create -d test")
      machine.succeed("snapper -c data2 list | grep -q test")

    with subtest("functional: snapraid sync on btrfs disks"):
      machine.succeed("echo hello > /mnt/data1/test.txt")
      machine.succeed("echo world > /mnt/data2/test.txt")
      machine.succeed("snapraid sync -c /etc/snapraid.conf")
      machine.succeed("test -s /mnt/parity/snapraid.parity")

    with subtest("full runner executes end-to-end"):
      # Runs snapraid-btrfs (snapper snapshots) + snapraid sync.
      machine.succeed("snapraid-btrfs-runner")

    with subtest("recover a failed data disk from parity"):
      # Make sure parity reflects the current state before the "failure".
      machine.succeed("snapraid sync -c /etc/snapraid.conf")
      expected = machine.succeed("cat /mnt/data2/test.txt").strip()

      # Simulate a TOTAL failure of the data2 disk (its data subvolume and
      # its content subvolume live on the same physical disk image). The
      # loop devices use autoclear, so unmounting them makes the data
      # inaccessible to snapraid.
      machine.succeed("umount /mnt/data2 && umount /mnt/content2; true")
      machine.succeed("! mountpoint -q /mnt/data2")
      machine.succeed("! mountpoint -q /mnt/content2")

      # Recover the failed disk's contents from parity. The metadata is read
      # from the surviving content file on disk1 (/mnt/content1).
      machine.succeed("snapraid -c /etc/snapraid.conf -d data2 fix")

      got = machine.succeed("cat /mnt/data2/test.txt").strip()
      print(f"recovered data2/test.txt: {got!r} (expected {expected!r})")
      assert got == expected, f"recovered content mismatch: {got!r} != {expected!r}"

      # And confirm the surviving disk is untouched.
      machine.succeed("test \"$(cat /mnt/data1/test.txt)\" = hello")
  '';
}
