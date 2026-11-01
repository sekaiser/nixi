# Keep package/module declarations unchanged; append consumer runtime preferences.
{pkgs}: {
  doomDir,
  extraConfig,
}:
if extraConfig == ""
then doomDir
else
  pkgs.runCommand "doom-config-with-extra" {
    extra = pkgs.writeText "doom-extra-config.el" extraConfig;
  } ''
    mkdir -p "$out"
    cp -RL ${doomDir}/. "$out/"
    chmod u+w "$out"
    if test -e "$out/config.el"; then
      chmod u+w "$out/config.el"
    fi
    printf '\n;; Consumer configuration follows shared defaults.\n' >> "$out/config.el"
    cat "$extra" >> "$out/config.el"
    printf '\n' >> "$out/config.el"
  ''
