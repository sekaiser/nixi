# Optional Cilium + Gateway API + Flux recipe, using Nixpkgs' K3s manifest and
# Helm-controller integration. Nothing is downloaded into /usr/bin at runtime.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.modules.profiles.k3s-cilium;
  native = config.services.k3s;
  active = native.enable;
  apiFlag = "--https-listen-port=${toString cfg.apiPort}";
  podFlag = "--cluster-cidr=${lib.concatStringsSep "," cfg.podCIDRs}";
  requiredNetworkFlags = [apiFlag podFlag "--flannel-backend=none" "--disable-network-policy" "--disable-kube-proxy"];
  managedNetworkFlags = ["--https-listen-port" "--cluster-cidr" "--flannel-backend" "--disable-network-policy" "--disable-kube-proxy"];
  networkFlagsAgree =
    builtins.isList native.extraFlags
    && lib.all (expected: lib.count (flag: flag == expected) native.extraFlags == 1) requiredNetworkFlags
    && lib.all (flag: !lib.any (name: lib.hasInfix name flag) managedNetworkFlags || builtins.elem flag requiredNetworkFlags)
    native.extraFlags;
  ipv4CIDR = cidr: let
    parts = builtins.match "(0|[1-9][0-9]{0,2})[.](0|[1-9][0-9]{0,2})[.](0|[1-9][0-9]{0,2})[.](0|[1-9][0-9]{0,2})/(0|[1-9][0-9]?)" cidr;
  in
    parts
    != null
    && lib.all (part: lib.toInt part <= 255) (lib.take 4 parts)
    && lib.toInt (lib.last parts) <= 32;
  # Native K3s turns chart values into a HelmChart manifest. Inspect that final
  # representation so forced valuesContent overrides cannot evade consistency.
  jsonAttrs = text:
    if builtins.isString text
    then let
      parsed = builtins.fromJSON text;
    in
      if builtins.isAttrs parsed
      then parsed
      else {}
    else {};
  chartManifest = jsonAttrs (native.autoDeployCharts.cilium.source.value or null);
  chartItems = chartManifest.items or [];
  chartItem = lib.findFirst (item: builtins.isAttrs item && (item.kind or null) == "HelmChart" && (item.metadata.name or null) == "cilium") {} (
    if builtins.isList chartItems
    then chartItems
    else []
  );
  effectiveValues = jsonAttrs (chartItem.spec.valuesContent or null);
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
    apiPort = lib.mkOption {
      type = lib.types.port;
      default = 6443;
      description = "API HTTPS port shared by K3s and Cilium's direct API connection.";
    };
    l2Interface = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Optional interface for L2 pod announcements; no workstation interface is assumed.";
    };
    podCIDRs = lib.mkOption {
      type = lib.types.listOf lib.types.nonEmptyStr;
      default = ["10.42.0.0/16"];
      description = "Single IPv4 pod CIDR shared by K3s and Cilium IPAM. This recipe does not configure dual-stack or multiple pools.";
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
        assertion = !active || cfg.apiHost != null;
        message = "k3s-cilium requires an explicit apiHost.";
      }
      {
        assertion = !active || native.role == "server";
        message = "k3s-cilium requires the effective K3s role to be server.";
      }
      {
        assertion = !active || (builtins.length cfg.podCIDRs == 1 && lib.all ipv4CIDR cfg.podCIDRs);
        message = "k3s-cilium requires exactly one IPv4 pod CIDR with valid octets and prefix length; compose native services for other IPAM topologies.";
      }
      {
        assertion = !active || networkFlagsAgree;
        message = "k3s-cilium requires canonical network flags matching apiPort/podCIDRs, with Flannel, network policy and kube-proxy disabled. Set the profile options and remove duplicate, split, missing or conflicting native flags.";
      }
      {
        assertion =
          !active
          || (
            native.autoDeployCharts.cilium.enable
            && (effectiveValues.k8sServiceHost or null)
            == cfg.apiHost
            && (effectiveValues.k8sServicePort or null) == cfg.apiPort
            && (effectiveValues.ipam.operator.clusterPoolIPv4PodCIDRList or null) == cfg.podCIDRs
            && (effectiveValues.ipam.mode or null) == "cluster-pool"
            && (effectiveValues.ipv4.enabled or null) == true
            && (effectiveValues.ipv6.enabled or null) == false
            && (effectiveValues.kubeProxyReplacement or null) == true
          );
        message = "k3s-cilium requires an enabled HelmChart with kube-proxy replacement and IPv4 cluster-pool IPAM matching apiHost/apiPort/podCIDRs; opaque or conflicting valuesContent is unsupported.";
      }
    ];
    environment.systemPackages = lib.mkIf active [pkgs.cilium-cli];
    services.k3s = lib.mkIf active {
      extraFlags = [
        apiFlag
        podFlag
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
            k8sServicePort = cfg.apiPort;
            kubeProxyReplacement = true;
            gatewayAPI.enabled = true;
            l2announcements.enabled = true;
            bpf.masquerade = true;
            socketLB.enabled = true;
            l7Proxy = true;
            ipv4.enabled = true;
            ipv6.enabled = false;
            # NodePort/external-IP support is part of kubeProxyReplacement;
            # their separate enable flags were removed in Cilium 1.19.
            ipam = {
              mode = "cluster-pool";
              operator.clusterPoolIPv4PodCIDRList = cfg.podCIDRs;
            };
            operator.replicas = 1;
            hubble.relay.enabled = true;
            hubble.ui.enabled = true;
          }
          // lib.optionalAttrs (cfg.l2Interface != null) {
            l2podAnnouncements.interfacePattern = "^${lib.escapeRegex cfg.l2Interface}$";
          };
      };
    };
    networking.firewall = lib.mkIf active {
      checkReversePath = "loose";
      trustedInterfaces = ["cilium_host" "cilium_net" "lxc+"];
    };
  };
}
