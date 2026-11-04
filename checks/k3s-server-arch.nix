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
    addonHost = plain.extendModules {
      modules = [
        {
          modules.profiles.k3s-cilium = {
            enable = true;
            apiHost = "k3s-check.example.invalid";
            flux.enable = true;
          };
        }
      ];
    };
    addons = addonHost.config;
    variant = module: (addonHost.extendModules {modules = [module];}).config;
    values = cfg: let
      manifest = builtins.fromJSON cfg.services.k3s.autoDeployCharts.cilium.source.value;
    in
      builtins.fromJSON (builtins.head manifest.items).spec.valuesContent;
    validNetwork = cfg: !lib.any (a: !a.assertion && lib.hasPrefix "k3s-cilium " a.message) cfg.assertions;
    custom = variant {
      modules.profiles.k3s-cilium = {
        apiPort = 7443;
        podCIDRs = ["192.0.2.0/24"];
      };
    };
    nativeValues = extra: {
      services.k3s.autoDeployCharts.cilium.values = lib.mkForce (lib.recursiveUpdate (values addons) extra);
    };
    invalidNetworks = map variant [
      {services.k3s.extraFlags = ["--https-listen-port=7443"];}
      {services.k3s.extraFlags = ["--https-listen-port 7443"];}
      {services.k3s.extraFlags = ["--https-listen-port" "6443"];}
      {services.k3s.extraFlags = ["--cluster-cidr=192.0.2.0/24"];}
      {services.k3s.extraFlags = ["--cluster-cidr=10.42.0.0/16"];}
      {services.k3s.extraFlags = ["--flannel-backend=vxlan"];}
      {services.k3s.extraFlags = ["--disable-kube-proxy=false"];}
      # Even matching API/CIDR flags cannot replace required CNI flags.
      {services.k3s.extraFlags = lib.mkForce ["--https-listen-port=6443" "--cluster-cidr=10.42.0.0/16"];}
      {services.k3s.extraFlags = lib.mkForce "--https-listen-port=6443 --cluster-cidr=10.42.0.0/16";}
      (nativeValues {k8sServicePort = 7443;})
      (nativeValues {k8sServiceHost = "other.example.invalid";})
      (nativeValues {ipam.operator.clusterPoolIPv4PodCIDRList = ["192.0.2.0/24"];})
      (nativeValues {ipam.mode = "kubernetes";})
      (nativeValues {ipv6.enabled = true;})
      (nativeValues {kubeProxyReplacement = false;})
      {services.k3s.autoDeployCharts.cilium.enable = false;}
      {services.k3s.autoDeployCharts.cilium.extraFieldDefinitions.spec.valuesContent = lib.mkForce "{}";}
      {modules.profiles.k3s-cilium.podCIDRs = [];}
      {modules.profiles.k3s-cilium.podCIDRs = ["192.0.2.0/24" "198.51.100.0/24"];}
      {modules.profiles.k3s-cilium.podCIDRs = ["2001:db8::/64"];}
      {modules.profiles.k3s-cilium.podCIDRs = ["256.0.0.0/16"];}
      {modules.profiles.k3s-cilium.podCIDRs = ["192.0.2.0/33"];}
    ];
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
    && !(addons.systemd.services ? k3s-flux2-bootstrap)
    && validNetwork addons
    && validNetwork custom
    && validNetwork (variant (nativeValues {debug.enabled = true;}))
    && (values custom).k8sServicePort == 7443
    && (values custom).ipam.operator.clusterPoolIPv4PodCIDRList == ["192.0.2.0/24"]
    && lib.hasInfix "--https-listen-port=7443" custom.systemd.services.k3s.serviceConfig.ExecStart
    && lib.hasInfix "--cluster-cidr=192.0.2.0/24" custom.systemd.services.k3s.serviceConfig.ExecStart
    && lib.all (cfg: !validNetwork cfg) invalidNetworks;
  actual = builtins.all check ["arm" "amd"];
in
  assert actual;
    runCommand "k3s-server-arch-check" {
      checked = builtins.toJSON actual;
    } ''
      touch "$out"
    ''
