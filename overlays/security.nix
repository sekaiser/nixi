# Temporary upstream security release override. Remove once all default pins
# provide the fixes. Review dates flag maintenance, never silently remove patches.
_final: prev: let
  fix = (builtins.fromJSON (builtins.readFile ../security/overrides.json)).overrides.openssl_3_6;
in {
  openssl_3_6 =
    if prev ? openssl_3_6 && prev.lib.versionOlder prev.openssl_3_6.version fix.fixedVersion
    then
      prev.openssl_3_6.overrideAttrs (_: {
        version = fix.fixedVersion;
        # OpenSSL bootstraps curl/fetchurl: use the dependency-free fetcher.
        src = prev.stdenv.fetchurlBoot fix.source;
      })
    else (prev.openssl_3_6 or prev.openssl);
}
