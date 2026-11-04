# Render the pinned bootstrap inputs on the check runner's native platform.
# Cross-platform host evaluation alone cannot exercise these derivations.
{
  lib,
  pkgs,
  runCommand,
  kubernetes-helm,
  python3,
  ...
}: let
  pins = import ../lib/internal/addon-pins.nix;
  evaluated = lib.evalModules {
    specialArgs = {inherit pkgs;};
    modules = [
      ../modules/platform/linux/profiles/k3s-cilium.nix
      {
        options = {
          modules.services.k3s-server.enable = lib.mkEnableOption "test K3s server";
          assertions = lib.mkOption {
            type = lib.types.listOf lib.types.attrs;
            default = [];
          };
          services.k3s = {
            enable = lib.mkEnableOption "synthetic native K3s";
            role = lib.mkOption {type = lib.types.str;};
            extraFlags = lib.mkOption {type = lib.types.listOf lib.types.str;};
            manifests = lib.mkOption {type = lib.types.attrs;};
            autoDeployCharts = lib.mkOption {type = lib.types.attrs;};
          };
          environment = lib.mkOption {type = lib.types.attrs;};
          networking = lib.mkOption {type = lib.types.attrs;};
        };
        config.modules = {
          services.k3s-server.enable = true;
          profiles.k3s-cilium = {
            enable = true;
            apiHost = "k3s.example.invalid";
            flux.enable = true;
          };
        };
        config.services.k3s = {
          enable = true;
          role = "server";
        };
      }
    ];
  };
  k3s = evaluated.config.services.k3s;
  chart = k3s.autoDeployCharts.cilium;
  # The lightweight schema above leaves nested mkIf properties intact.
  flux = k3s.manifests.nixi-flux-bootstrap;
  values = pkgs.writeText "cilium-values.json" (builtins.toJSON chart.values);
  customNetwork =
    (evaluated.extendModules {
      modules = [
        {
          modules.profiles.k3s-cilium = {
            apiPort = 7443;
            podCIDRs = ["192.0.2.0/24"];
          };
        }
      ];
    })
    .config.services.k3s;
  customValues = pkgs.writeText "cilium-custom-values.json" (builtins.toJSON customNetwork.autoDeployCharts.cilium.values);
  replacement = pkgs.writeText "fixture-chart" "fixture";
  overridden =
    (evaluated.extendModules {
      modules = [
        {
          modules.profiles.k3s-cilium = {
            chartPackage = replacement;
            gatewayAPIManifest = replacement;
            l2Interface = "eth.0";
            podCIDRs = ["192.0.2.0/24"];
            apiPort = 7443;
          };
        }
      ];
    })
    .config
    .services
    .k3s;
in
  assert overridden.autoDeployCharts.cilium.package.content == replacement;
  assert overridden.manifests.nixi-gateway-api.source.content == replacement;
  assert overridden.autoDeployCharts.cilium.values.l2podAnnouncements.interfacePattern == "^eth\\.0$";
  assert overridden.autoDeployCharts.cilium.values.ipam.operator.clusterPoolIPv4PodCIDRList == ["192.0.2.0/24"];
  assert overridden.autoDeployCharts.cilium.values.k8sServicePort == 7443;
  assert chart.extraFieldDefinitions.spec.bootstrap;
  assert flux.condition;
    runCommand "k3s-addon-manifests-check" {
      nativeBuildInputs = [kubernetes-helm (python3.withPackages (ps: [ps.pyyaml]))];
    } ''
      helm template cilium ${chart.package.content} --namespace kube-system \
        --kube-version ${pins.cilium.renderKubernetesVersion} --values ${values} > cilium.yaml
      helm template cilium ${chart.package.content} --namespace kube-system \
        --kube-version ${pins.cilium.renderKubernetesVersion} --values ${customValues} > cilium-custom.yaml
      python - ${k3s.manifests.nixi-gateway-api.source.content} ${flux.content.source} <<'PY'
      import sys, yaml
      from pathlib import Path
      gateway = list(yaml.safe_load_all(Path(sys.argv[1]).read_text()))
      assert len(gateway) == 6
      assert all(item['kind'] == 'CustomResourceDefinition' for item in gateway)
      flux = list(yaml.safe_load_all(Path(sys.argv[2]).read_text()))
      assert any(item and item['kind'] == 'Deployment' for item in flux)
      assert any(item and item['kind'] == 'NetworkPolicy' for item in flux)
      cilium = list(yaml.safe_load_all(Path('cilium.yaml').read_text()))
      assert any(item and item['kind'] == 'DaemonSet' for item in cilium)
      agent = next(item for item in cilium if item and item['kind'] == 'DaemonSet' and item['metadata']['name'] == 'cilium')
      image = agent['spec']['template']['spec']['containers'][0]['image']
      assert ':v1.19.7@sha256:' in image, image
      for filename, port, cidr in [('cilium.yaml', '6443', '10.42.0.0/16'),
                                   ('cilium-custom.yaml', '7443', '192.0.2.0/24')]:
          objects = [obj for obj in yaml.safe_load_all(Path(filename).read_text()) if obj]
          agent = next(obj for obj in objects if obj['kind'] == 'DaemonSet' and obj['metadata']['name'] == 'cilium')
          environment = {entry['name']: entry.get('value') for entry in agent['spec']['template']['spec']['containers'][0]['env']}
          assert environment['KUBERNETES_SERVICE_HOST'] == 'k3s.example.invalid'
          assert environment['KUBERNETES_SERVICE_PORT'] == port
          config = next(obj for obj in objects if obj['kind'] == 'ConfigMap' and obj['metadata']['name'] == 'cilium-config')
          assert config['data']['cluster-pool-ipv4-cidr'] == cidr
      assert all(item['metadata']['annotations']['gateway.networking.k8s.io/bundle-version'] == 'v1.4.1' for item in gateway)
      PY
      touch "$out"
    ''
