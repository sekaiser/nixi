# Reviewed independently of flake.lock. Update the compatible pair together;
# see docs/dependencies.md for the release/security review procedure.
{
  cilium = {
    version = "1.19.7";
    url = "https://helm.cilium.io/cilium-1.19.7.tgz";
    hash = "sha256-BHGBQNr8jgFHI2P7V1QRnArv3xgwe39cBJOzdDE+3rI=";
    kubernetesVersions = ["1.32" "1.33" "1.34" "1.35"];
    renderKubernetesVersion = "1.35.0";
  };
  gatewayAPI = {
    version = "1.4.1";
    url = "https://github.com/kubernetes-sigs/gateway-api/archive/refs/tags/v1.4.1.tar.gz";
    hash = "sha256-/GHyikcC2QGDN0ndpY6/xvSEEnpSsLrNU+lFElCKBs8=";
  };
}
