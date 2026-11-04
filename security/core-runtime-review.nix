# Explicit public-proposal acceptance; never evaluate a private host here.
# Review the plan before building. This boots one disposable Linux guest and
# changes only that guest's synthetic state. It does not change input locks.
{
  root,
  guestRoot ? root,
  system ? "aarch64-linux",
  allowSoftwareEmulation ? false,
}:
assert builtins.elem system ["aarch64-linux" "x86_64-linux"];
assert builtins.pathExists (root + "/release-files.json");
assert !(builtins.pathExists (root + "/hosts"));
assert builtins.pathExists (guestRoot + "/release-files.json");
assert !(builtins.pathExists (guestRoot + "/hosts")); let
  proposal = builtins.getFlake ("path:" + root);
  guest = builtins.getFlake ("path:" + guestRoot);
  pkgs = import guest.inputs.nixpkgs {inherit system;};
  core = proposal.packages.${system}.tencent-memory-core;
  installer = proposal.packages.${system}.install-user-file;
  startupSeconds =
    if allowSoftwareEmulation
    then "180"
    else "10";
in
  pkgs.testers.runNixOSTest {
    name = "nixi-proposed-core-runtime-acceptance";
    requiredFeatures = pkgs.lib.optionalAttrs allowSoftwareEmulation {
      kvm = false;
      apple-virt = false;
      nixos-test = false;
    };
    qemu.forceAccel = !allowSoftwareEmulation;
    globalTimeout = 420;
    nodes.machine = {pkgs, ...}: {
      users.users.recipient.isNormalUser = true;
      environment.systemPackages = [pkgs.python3 core installer];
      # Smaller 768/1536 MiB guests exhausted memory during TypeScript startup;
      # the latter reported about 1.29 GiB resident in Node's MainThread alone.
      # This is a bounded test allocation, not a production memory requirement.
      virtualisation.memorySize = 3072;
      virtualisation.cores = 2;
    };
    testScript = ''
      machine.start()
      machine.wait_for_unit("multi-user.target")
      base = "runuser -u recipient -- env -i HOME=/home/recipient TMPDIR=/tmp PATH=/run/current-system/sw/bin NIXI_MEMORY_CORE=${core}/bin/tencent-memory-core NIXI_MEMORY_NODE=${core.nodejs}/bin/node NIXI_TEST_INSTALLER=${installer}/bin/nixi-install-user-file PYTHONDONTWRITEBYTECODE=1 NIXI_TEST_CORE_STARTUP_SECONDS=${startupSeconds} "
      with subtest("proposed Node runtime identity"):
          machine.succeed("${core.nodejs}/bin/node -p 'JSON.stringify(process.versions)'")
      with subtest("real Core auth isolation and qualified roundtrip plus strict HTTP integrity"):
          machine.succeed(base + "python3 ${proposal.outPath}/test_tools/test_agent_memory.py", timeout=240)
      with subtest("installer positive and adversarial runtime suite with actual root ancestry"):
          machine.succeed(base + "python3 ${proposal.outPath}/test_tools/test_install_user_file.py", timeout=60)
      with subtest("recipient receipt lifecycle and packaged CLI with actual root ancestry"):
          machine.succeed(base + "python3 ${proposal.outPath}/test_tools/test_tracked_user_file.py", timeout=90)
      machine.shutdown()
    '';
  }
