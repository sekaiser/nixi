{
  lib,
  config,
  options,
  pkgs,
  ...
}: let
  inherit (lib) mkDefault mkIf;
in {
  config = mkIf (config.modules.profiles.platform == "cilium-vm") ({
      assertions = [
        {
          assertion = options ? disko;
          message = "The cilium-vm profile requires an explicit import of nixi.nixosModules.disko (or the legacy qcow-efi target).";
        }
      ];
      system.stateVersion = "25.05";
      nixpkgs.hostPlatform = mkDefault pkgs.stdenv.hostPlatform.system;

      boot.loader.systemd-boot.enable = true;
      boot.loader.efi.efiSysMountPoint = "/boot/";
      boot.loader.efi.canTouchEfiVariables = true;
      boot.kernelParams = [
        "net.ipv4.conf.default.rp_filter=0"
        "systemd.unified_cgroup_hierarchy=1"

        # Improve BPF performance
        "net.core.bpf_jit_enable=1"
        "net.ipv4.conf.all.rp_filter=0"

        # Required for Cilium's BPF masquerading
        "net.ipv4.ip_forward=1"
        "net.ipv6.conf.all.forwarding=1"
      ];
      boot.initrd.availableKernelModules = ["xhci_pci"];
      boot.initrd.kernelModules = [];
      boot.kernelModules = [
        "bpf_jit" # BPF program execution speed
        "bpfilter" # BPF-based packet filtering
        "bpf"
        "xt_bpf" # BPF-based iptables replacement (for compatibility)
        "br_netfilter" # Bridge filtering (for CNI)

        # Conntrack (required for L4/L7 policies)
        "nf_conntrack"
        "nf_conntrack_ipv4"
        "nf_conntrack_ipv6"

        "xt_mark" # L7 proxy features

        "xt_socket" # Socket matching (for L7 redirection)
        "xt_comment" # Metadata for BPF rules

        # not actively used, for compatibility
        "ip_tables"
        "iptable_mangle"
        "ip6_tables" # If using IPv6

        "overlay" # Cilium’s encap-mode=overlay

        "nf_tables"

        "x_tables"
        "netfilter"
        "nf_net"
        "iptable_raw"
      ];
      boot.kernel.sysctl = {
        "net.ipv4.ip_forward" = 1; # IPv4 forwarding
        "net.ipv6.conf.all.forwarding" = 1; # IPv6 forwarding
        "kernel.unprivileged_bpf_disabled" = 1; # Disallow unprivileged BPF
        "net.core.bpf_jit_enable" = 1;
        "net.ipv4.conf.all.rp_filter" = 0;
        "net.ipv6.conf.all.disable_ipv6" = 0;
      };
      boot.extraModulePackages = [];
      # clear /tmp on boot to get a stateless /tmp directory.
      boot.tmp.cleanOnBoot = true;
      # supported file systems, so we can mount any removable disks with these filesystems
      boot.supportedFilesystems = [
        "ext4"
        "xfs"
        "vfat"
        "xfs"
      ];

      fileSystems."/sys/fs/bpf" = {
        fsType = "bpf";
        device = "/dev/sda";
        options = ["rw" "nosuid" "nodev" "noexec" "relatime" "mode=700"];
      };

      # Enables DHCP on each ethernet and wireless interface. In case of scripted networking
      # (the default) this is the recommended approach. When using systemd-networkd it's
      # still possible to use this option, but it's recommended to use it in conjunction
      # with explicit per-interface declarations with `networking.interfaces.<interface>.useDHCP`.
      networking.useDHCP = mkDefault true;
    }
    // lib.optionalAttrs (options ? disko) {
      disko.devices = {
        disk.vda = {
          device = "/dev/vda";
          type = "disk";
          content = {
            type = "gpt";
            partitions = {
              boot = {
                name = "boot";
                size = "1M";
                type = "EF02";
              };
              esp = {
                name = "ESP";
                size = "500M";
                type = "EF00";
                content = {
                  type = "filesystem";
                  format = "vfat";
                  mountpoint = "/boot";
                };
              };
              root = {
                name = "root";
                size = "100%";
                content = {
                  type = "lvm_pv";
                  vg = "pool";
                };
              };
            };
          };
        };
        lvm_vg = {
          pool = {
            type = "lvm_vg";
            lvs = {
              root = {
                size = "100%FREE";
                content = {
                  type = "filesystem";
                  format = "ext4";
                  mountpoint = "/";
                  mountOptions = [
                    "defaults"
                    "noatime"
                  ];
                };
              };
            };
          };
        };
      };
    });
}
