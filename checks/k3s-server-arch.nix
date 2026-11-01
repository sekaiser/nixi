{
  nixi,
  lib,
  runCommand,
  ...
}: let
  hostModule = system: {...}: {
    config = {...}: {
      user = {
        name = "k3s-check";
        home = "/home/k3s-check";
      };
      system.stateVersion = "26.05";
      home.stateVersion = "26.05";
      nixpkgs.hostPlatform = system;

      modules.services.k3s-server = {
        enable = true;
        k8sServiceHost = "k3s-check.example.invalid";
      };
    };
  };

  outputs = nixi.lib.mkHostFlake {
    inputs = nixi.inputs // {self = nixi;};
    systems = ["aarch64-linux" "x86_64-linux"];
    hosts = {
      arm = {
        system = "aarch64-linux";
        module = hostModule "aarch64-linux";
      };
      amd = {
        system = "x86_64-linux";
        module = hostModule "x86_64-linux";
      };
    };
  };

  check = host: let
    plain = outputs.nixosConfigurations.${host};
    addons =
      (plain.extendModules {
        modules = [
          {
            modules.profiles.k3s-cilium = {
              enable = true;
              apiHost = "k3s-check.example.invalid";
              flux.enable = true;
            };
          }
        ];
      })
      .config;
    nativeOverride =
      (plain.extendModules {
        modules = [
          {
            modules.profiles.k3s-cilium = {
              enable = true;
              apiHost = "k3s-check.example.invalid";
            };
            services.k3s.autoDeployCharts.cilium.package = /fixture/native-chart.tgz;
            services.k3s.manifests.nixi-gateway-api.source = /fixture/native-crds.yaml;
          }
        ];
      })
      .config;
  in
    plain.config.networking.firewall.enable
    && builtins.elem "--write-kubeconfig-mode=0600" plain.config.services.k3s.extraFlags
    && !plain.config.services.tailscale.enable
    && plain.config.services.k3s.autoDeployCharts == {}
    && !(plain.config.environment.etc ? "cilium/install.sh")
    && addons.networking.firewall.enable
    && addons.services.k3s.autoDeployCharts.cilium.package.src.outputHash == (import ../lib/internal/addon-pins.nix).cilium.hash
    && addons.services.k3s.autoDeployCharts.cilium.package.version == "1.19.7"
    && builtins.elem (lib.versions.majorMinor (lib.removePrefix "v" plain.config.services.k3s.package.version)) (import ../lib/internal/addon-pins.nix).cilium.kubernetesVersions
    && nativeOverride.services.k3s.autoDeployCharts.cilium.package == /fixture/native-chart.tgz
    && nativeOverride.services.k3s.manifests.nixi-gateway-api.source == /fixture/native-crds.yaml
    && addons.services.k3s.autoDeployCharts.cilium.enable
    && addons.services.k3s.manifests ? nixi-flux-bootstrap
    && !(addons.systemd.services ? k3s-flux2-bootstrap);
  actual = builtins.all check ["arm" "amd"];
in
  assert actual;
    runCommand "k3s-server-arch-check" {
      checked = builtins.toJSON actual;
    } ''
      touch "$out"
    ''
