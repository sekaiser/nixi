{
  nixi,
  runCommand,
  ...
}: let
  inherit (builtins) deepSeq tryEval;

  normalize = nixi.lib.normalizeHostDescriptor;
  importDescriptor = nixi.lib.importHostDescriptor;

  valid =
    normalize "valid" {
      path = ./fixtures/host-descriptor-contract/valid.nix;
      config = importDescriptor ./fixtures/host-descriptor-contract/valid.nix;
    };
  functionDescriptor =
    normalize "function" {
      path = ./fixtures/host-descriptor-contract/function.nix;
      config = importDescriptor ./fixtures/host-descriptor-contract/function.nix;
    };

  rejects = descriptor:
    ! (tryEval (deepSeq (normalize "bad" descriptor) true)).success;

  actual = {
    validSystem = valid.config.system;
    validTarget = valid.config.target;
    functionSystem = functionDescriptor.config.system;
    functionTarget = functionDescriptor.config.target;
    rejectsMissingModule =
      rejects {
        path = "<missing-module>";
        config = {
          system = "aarch64-linux";
        };
      };
    rejectsUnsupportedSystem =
      rejects {
        path = "<bad-system>";
        config = {
          system = "riscv64-linux";
          module = {...}: {};
        };
      };
    rejectsUnsupportedTarget =
      rejects {
        path = "<bad-target>";
        config = {
          system = "aarch64-linux";
          target = "iso";
          module = {...}: {};
        };
      };
  };

  expected = {
    validSystem = "aarch64-linux";
    validTarget = "runtime";
    functionSystem = "x86_64-linux";
    functionTarget = "qcow-efi";
    rejectsMissingModule = true;
    rejectsUnsupportedSystem = true;
    rejectsUnsupportedTarget = true;
  };
in
  assert actual == expected;
  runCommand "host-descriptor-contract-check" {
    checked = builtins.toJSON actual;
  } ''
    touch "$out"
  ''
