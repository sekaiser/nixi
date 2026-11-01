{
  hey,
  lib,
  config,
  pkgs,
  ...
}: let
  inherit (builtins) filter hasAttr map throw;
  inherit (lib) concatStringsSep mkAfter mkDefault mkIf types;
  inherit (hey.lib) mkBoolOpt' mkOpt';

  cfg = config.modules.profiles.vm-image;
  unknownPackages = filter (name: !(hasAttr name pkgs)) cfg.extraPackages;
  resolvePackage = name:
    pkgs.${name} or (throw "Unknown vm-image extra package: ${name}");
in {
  options.modules.profiles.vm-image = {
    enable = mkBoolOpt' false "Whether to configure this host as a prebuilt VM image.";
    hostName = mkOpt' types.str config.networking.hostName "Hostname to bake into the VM image.";
    stateVersion = mkOpt' types.str "26.05" "NixOS state version for the generated image.";
    diskSize = mkOpt' types.int 51200 "Virtual disk size in MiB.";
    activationUser = mkOpt' types.str config.user.name "User allowed to activate copied system closures without a password.";
    allowPasswordlessActivation = mkBoolOpt' false "Explicitly grant administrative authority to activate user-built system closures without a password.";
    passwordAuthentication = mkBoolOpt' false "Whether SSH password authentication is enabled in the image.";
    trustedUserCAKeys = mkOpt' (types.listOf types.str) [] "OpenSSH user CA public keys trusted by the image.";
    hostCertificates = mkOpt' (types.attrsOf types.attrs) {} "OpenSSH host certificates to install or sign for this VM image.";
    extraPackages = mkOpt' (types.listOf types.str) [] "Additional package names from pkgs to install for the image user.";
    autoCleanGenerations = mkBoolOpt' true "Whether hey may automatically clean old system generations on this VM.";
    keepGenerations = mkOpt' (types.ints.between 1 2147483647) 3 "Number of recent system generations to retain during cleanup.";
    ssdOptimizations = mkBoolOpt' true "Whether to enable SSD-friendly filesystem options such as noatime and fstrim.";
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.hostName != "";
        message = "modules.profiles.vm-image.hostName must not be empty.";
      }
      {
        assertion = cfg.activationUser != "";
        message = "modules.profiles.vm-image.activationUser must not be empty.";
      }
      {
        assertion = cfg.diskSize > 0;
        message = "modules.profiles.vm-image.diskSize must be greater than 0 MiB.";
      }
      {
        assertion = !cfg.ssdOptimizations || config.modules.services.journald.enable;
        message = "modules.profiles.vm-image.ssdOptimizations requires modules.services.journald.enable.";
      }
      {
        assertion = !cfg.ssdOptimizations || config.modules.services.journald.systemMaxUse != "";
        message = "modules.profiles.vm-image.ssdOptimizations requires modules.services.journald.systemMaxUse to be set.";
      }
      {
        assertion = !cfg.ssdOptimizations || config.modules.services.journald.runtimeMaxUse != "";
        message = "modules.profiles.vm-image.ssdOptimizations requires modules.services.journald.runtimeMaxUse to be set.";
      }
      {
        assertion = unknownPackages == [];
        message = "modules.profiles.vm-image.extraPackages contains unknown package names: ${concatStringsSep ", " unknownPackages}";
      }
    ];

    hey.enable = mkDefault true;
    hey.info.profiles.vm-image = {
      schemaVersion = 1;
      inherit (cfg) enable autoCleanGenerations keepGenerations;
    };

    system.stateVersion = cfg.stateVersion;

    networking.hostName = cfg.hostName;
    networking.useDHCP = mkDefault true;

    services.qemuGuest.enable = mkDefault true;
    services.fstrim.enable = mkDefault cfg.ssdOptimizations;

    modules.services.ssh = {
      enable = mkDefault true;
      passwordAuthentication = mkDefault cfg.passwordAuthentication;
      trustedUserCAKeys = mkIf (cfg.trustedUserCAKeys != []) cfg.trustedUserCAKeys;
      hostCertificates = mkIf (cfg.hostCertificates != {}) cfg.hostCertificates;
    };

    security.sudo.extraRules = mkIf cfg.allowPasswordlessActivation [
      {
        users = [cfg.activationUser];
        commands = [
          {
            command = "/nix/store/*-nixos-system-${cfg.hostName}-*/bin/switch-to-configuration switch";
            options = ["NOPASSWD"];
          }
          {
            command = "/nix/store/*-nixos-system-${cfg.hostName}-*/bin/switch-to-configuration boot";
            options = ["NOPASSWD"];
          }
          {
            command = "/nix/store/*-nix-*/bin/nix-env --profile /nix/var/nix/profiles/system --set /nix/store/*-nixos-system-${cfg.hostName}-*";
            options = ["NOPASSWD"];
          }
          {
            command = "/nix/store/*-nix-*/bin/nix-env --profile /nix/var/nix/profiles/system --rollback";
            options = ["NOPASSWD"];
          }
          {
            command = "/nix/store/*-nix-*/bin/nix-env --profile /nix/var/nix/profiles/system --list-generations";
            options = ["NOPASSWD"];
          }
          {
            command = "/nix/store/*-nix-*/bin/nix-env --profile /nix/var/nix/profiles/system --delete-generations +[0-9]*";
            options = ["NOPASSWD"];
          }
        ];
      }
    ];

    user.packages = map resolvePackage cfg.extraPackages;

    virtualisation.diskSize = mkDefault cfg.diskSize;
    nixpkgs.hostPlatform = mkDefault pkgs.stdenv.hostPlatform.system;

    fileSystems."/" = {
      device = mkDefault "/dev/disk/by-label/nixos";
      autoResize = mkDefault true;
      fsType = mkDefault "ext4";
      options = mkIf cfg.ssdOptimizations (mkAfter ["noatime"]);
    };
    fileSystems."/boot" = {
      device = mkDefault "/dev/disk/by-label/ESP";
      fsType = mkDefault "vfat";
    };

    boot.loader.systemd-boot.enable = mkDefault true;
    boot.loader.efi.canTouchEfiVariables = mkDefault true;
    boot.initrd.availableKernelModules = mkDefault ["xhci_pci"];
    boot.tmp.cleanOnBoot = mkDefault true;
    boot.supportedFilesystems = mkDefault ["ext4" "vfat"];
  };
}
