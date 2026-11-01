{
  nixi,
  lib,
  runCommand,
  ...
}: let
  module = _: {
    config = {lib, ...}: {
      options.modules.profiles.private = lib.mkOption {type = lib.types.attrs;};
      config = {
        user.name = "alice";
        home.stateVersion = "26.05";
        hey.enable = true;
        modules.profiles = {
          user = "alice";
          role = "fixture";
          # Publishing runtime metadata must not evaluate unrelated settings.
          private.credentials = throw "private profile data must not be serialized";
        };
      };
    };
  };
  outputs = nixi.lib.mkHostFlake {
    inputs = {
      self.outPath = ./fixtures/cli-host;
      inherit nixi;
    };
    hosts = {
      linux = {
        system = "x86_64-linux";
        inherit module;
      };
      darwin = {
        system = "aarch64-darwin";
        inherit module;
      };
    };
  };
  linux = outputs.nixosConfigurations.linux;
  darwin = outputs.darwinConfigurations.darwin;
  vm = linux.extendModules {
    modules = [
      {
        modules.profiles.vm-image = {
          enable = true;
          keepGenerations = 9;
        };
      }
    ];
  };
  overridden = vm.extendModules {
    modules = [
      {
        modules.profiles.vm-image = {
          autoCleanGenerations = false;
          keepGenerations = lib.mkForce 7;
        };
      }
    ];
  };
  privilegedVm = vm.extendModules {modules = [{modules.profiles.vm-image.allowPasswordlessActivation = true;}];};
  expected = {
    user = "alice";
    role = "fixture";
    platform = "";
    hardware = [];
    networks = [];
  };
  profiles = host: builtins.fromJSON (builtins.toJSON host.config.hey.info.profiles);
in
  assert vm.config.security.sudo.extraRules == linux.config.security.sudo.extraRules;
  assert builtins.length privilegedVm.config.security.sudo.extraRules > builtins.length vm.config.security.sudo.extraRules;
  assert profiles linux == expected;
  assert profiles darwin == expected;
  assert profiles vm
  == expected
  // {
    vm-image = {
      schemaVersion = 1;
      enable = true;
      autoCleanGenerations = true;
      keepGenerations = 9;
    };
  };
  assert profiles overridden
  == expected
  // {
    vm-image = {
      schemaVersion = 1;
      enable = true;
      autoCleanGenerations = false;
      keepGenerations = 7;
    };
  };
    runCommand "runtime-metadata-check" {} ''touch "$out"''
