# Optional Cilium + Gateway API + Flux recipe, using Nixpkgs' K3s manifest and
# Helm-controller integration. Nothing is downloaded into /usr/bin at runtime.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.modules.profiles.k3s-cilium;
  pins = import ../../../../lib/internal/addon-pins.nix;
  chartSource = pkgs.fetchzip {inherit (pins.cilium) url hash;};
  # Normalize transport compression into a deterministic Helm-compatible tgz.
  chart =
    pkgs.runCommand "cilium-${pins.cilium.version}.tgz" {
      nativeBuildInputs = [pkgs.gnutar pkgs.gzip];
      passthru.src = chartSource;
      passthru.version = pins.cilium.version;
    } ''
      mkdir cilium
      cp -R ${chartSource}/. cilium/
      tar --sort=name --mtime=@1 --owner=0 --group=0 --numeric-owner \
        -cf - cilium | gzip -n > "$out"
    '';
  gateway = pkgs.fetchzip {inherit (pins.gatewayAPI) url hash;};
  gatewayCRDs = pkgs.runCommand "gateway-api-${pins.gatewayAPI.version}.yaml" {} ''
    for name in gatewayclasses gateways httproutes referencegrants grpcroutes; do
      cat "${gateway}/config/crd/standard/gateway.networking.k8s.io_$name.yaml" >> "$out"
      printf '\n---\n' >> "$out"
    done
    cat "${gateway}/config/crd/experimental/gateway.networking.k8s.io_tlsroutes.yaml" >> "$out"
  '';
  fluxManifest =
    pkgs.runCommand "flux-${pkgs.fluxcd.version}-bootstrap.yaml" {
      nativeBuildInputs = [pkgs.fluxcd pkgs.writableTmpDirAsHomeHook];
    } ''
      flux install --export > "$out"
    '';
in {
  options.modules.profiles.k3s-cilium = {
    enable = lib.mkEnableOption "K3s with pinned Cilium and Gateway API";
    chartPackage = lib.mkOption {
      type = lib.types.package;
      default = chart;
      description = "Pinned Cilium Helm chart archive. Override together with gatewayAPIManifest when choosing a different compatibility pair.";
    };
    gatewayAPIManifest = lib.mkOption {
      type = lib.types.package;
      default = gatewayCRDs;
      description = "Pinned Gateway API CRD manifest compatible with chartPackage.";
    };
    apiHost = lib.mkOption {
      type = lib.types.nullOr lib.types.nonEmptyStr;
      default = null;
      description = "Directly reachable API hostname (Cilium replaces kube-proxy).";
    };
    l2Interface = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Optional interface for L2 pod announcements; no workstation interface is assumed.";
    };
    podCIDRs = lib.mkOption {
      type = lib.types.listOf lib.types.nonEmptyStr;
      default = ["10.42.0.0/16"];
      description = "IPv4 pod pools for Cilium IPAM. Keep these consistent with the K3s cluster CIDR.";
    };
    flux.enable = lib.mkEnableOption "Nix-pinned Flux bootstrap manifests";
  };
  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = config.modules.services.k3s-server.enable;
        message = "k3s-cilium requires modules.services.k3s-server.enable.";
      }
      {
        assertion = cfg.apiHost != null;
        message = "k3s-cilium requires an explicit apiHost.";
      }
    ];
    environment.systemPackages = [pkgs.cilium-cli];
    services.k3s = {
      extraFlags = [
        "--flannel-backend=none"
        "--disable-network-policy"
        "--disable=servicelb"
        "--disable=traefik"
        "--disable-cloud-controller"
        "--disable-kube-proxy"
        "--kubelet-arg=register-with-taints=node.cilium.io/agent-not-ready:NoExecute"
      ];
      manifests.nixi-gateway-api.source = lib.mkDefault cfg.gatewayAPIManifest;
      manifests.nixi-flux-bootstrap = lib.mkIf cfg.flux.enable {source = fluxManifest;};
      autoDeployCharts.cilium = {
        # Native K3s supplies its fetchHelm fallback at mkDefault priority.
        # Beat that fallback without blocking an ordinary native override.
        package = lib.mkOverride 900 cfg.chartPackage;
        targetNamespace = "kube-system";
        extraFieldDefinitions.spec.bootstrap = true;
        values =
          {
            k8sServiceHost = cfg.apiHost;
            k8sServicePort = 6443;
            kubeProxyReplacement = true;
            gatewayAPI.enabled = true;
            l2announcements.enabled = true;
            bpf.masquerade = true;
            socketLB.enabled = true;
            l7Proxy = true;
            # NodePort/external-IP support is part of kubeProxyReplacement;
            # their separate enable flags were removed in Cilium 1.19.
            ipam.operator.clusterPoolIPv4PodCIDRList = cfg.podCIDRs;
            operator.replicas = 1;
            hubble.relay.enabled = true;
            hubble.ui.enabled = true;
          }
          // lib.optionalAttrs (cfg.l2Interface != null) {
            l2podAnnouncements.interfacePattern = "^${lib.escapeRegex cfg.l2Interface}$";
          };
      };
    };
    networking.firewall = {
      checkReversePath = "loose";
      trustedInterfaces = ["cilium_host" "cilium_net" "lxc+"];
    };
  };
}
