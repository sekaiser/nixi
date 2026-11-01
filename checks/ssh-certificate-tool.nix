{
  pkgs,
  python3,
  openssh,
  runCommand,
  ...
}: let
  tool = pkgs.callPackage ../packages/ssh-certificate.nix {};
  python = python3.withPackages (ps: [ps.cryptography]);
in
  runCommand "ssh-certificate-tool-check" {
    src = ../.;
    nativeBuildInputs = [python openssh];
  } ''
    export PYTHONDONTWRITEBYTECODE=1
    export NIXI_CERTIFICATE_TOOL=${tool}/bin/nixi-ssh-certificate
    python "$src/test_tools/test_ssh_certificate.py"
    touch "$out"
  ''
