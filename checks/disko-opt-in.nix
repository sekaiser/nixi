{
  nixi,
  lib,
  runCommand,
  ...
}: let
  withoutDisko = nixi // {inputs = removeAttrs nixi.inputs ["disko"];};
  make = framework: hosts:
    nixi.lib.mkHostFlake {
      nixi = framework;
      inputs.self.outPath = ./fixtures/cli-host;
      inherit hosts;
    };
  host = imports: {
    system = "x86_64-linux";
    module = _: {
      inherit imports;
      config = {
        user = {
          name = "alice";
          home = "/fixture/alice";
        };
        home.stateVersion = "26.05";
        system.stateVersion = "26.05";
      };
    };
  };
  ordinary = host [];
  explicit = host [../modules/optional/disko.nix];
  legacy = ordinary // {target = "qcow-efi";};
  outputs = make nixi {inherit ordinary explicit legacy;};
  missingProvider = make withoutDisko {inherit ordinary explicit legacy;};
  hasDisko = outputs: name: outputs.nixosConfigurations.${name}.options ? disko;
  rejects = value: !(builtins.tryEval (builtins.deepSeq value true)).success;
  normalized = nixi.lib.normalizeHostDescriptor "legacy" {
    path = "<fixture>";
    config = legacy;
  };
  cilium = name:
    (outputs.nixosConfigurations.${name}.extendModules {
      modules = [
        {
          modules.profiles.platform = "cilium-vm";
          system.stateVersion = lib.mkForce "25.05";
        }
      ];
    })
    .config;
in
  assert !(hasDisko outputs "ordinary");
  assert !(hasDisko missingProvider "ordinary");
  assert hasDisko outputs "explicit";
  assert hasDisko outputs "legacy";
  assert rejects (hasDisko missingProvider "explicit");
  assert rejects (hasDisko missingProvider "legacy");
  assert hasDisko (make nixi {legacy = normalized;}) "legacy";
  assert (cilium "explicit").disko.devices.disk.vda.device == "/dev/vda";
  assert (cilium "legacy").disko.devices.lvm_vg.pool.lvs.root.content.mountpoint == "/";
  assert lib.any (a: !a.assertion && lib.hasInfix "explicit import" a.message) (cilium "ordinary").assertions;
  assert rejects (nixi.lib.normalizeHostDescriptor "invalid" {
    path = "<fixture>";
    config = legacy // {system = "aarch64-darwin";};
  });
    runCommand "disko-opt-in-check" {} ''touch "$out"''
