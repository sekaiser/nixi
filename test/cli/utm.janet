(use hey)
(import hey/process)
(use ./support)

(defn run []
  (let [hey-bin (path :bin "hey")
        commands @[
          ["utm update" @[hey-bin "-!" "utm" "update" "utm"]]
          ["utm rollback" @[hey-bin "-!" "utm" "rollback" "utm"]]
          ["utm generations" @[hey-bin "-!" "utm" "generations" "utm"]]
          ["utm cleanup-generations" @[hey-bin "-!" "utm" "cleanup-generations" "utm"]]
          ["utm cleanup-generations override" @[hey-bin "-!" "utm" "cleanup-generations" "utm" "--keep-generations" "5"]]
          ["utm diff" @[hey-bin "-!" "utm" "diff" "utm"]]
          ["utm current" @[hey-bin "-!" "utm" "current" "utm"]]
          ["utm check" @[hey-bin "-!" "utm" "check" "utm"]]
          ["utm doctor" @[hey-bin "-!" "utm" "doctor" "utm"]]
          ["utm start" @[hey-bin "-!" "utm" "start" "utm"]]
          ["utm stop" @[hey-bin "-!" "utm" "stop" "utm"]]
          ["utm ssh" @[hey-bin "-!" "utm" "ssh" "utm" "hostname"]]
          ["utm create-image" @[hey-bin "-!" "utm" "create-image" "--vm" "utm" "--flake" ".#utm" "--cpu" "2" "--ram" "8192" "--phases" "start,doctor" "--force" "--yes"]]]
        output-commands @[
          ["utm update external flake" @[hey-bin "-!" "utm" "update" "vm-a" "--flake" "/tmp/site#vm-a"] "/tmp/site#nixosConfigurations.vm-a.config.system.build.toplevel"]
          ["utm diff external flake" @[hey-bin "-!" "utm" "diff" "vm-a" "--flake" "/tmp/site#vm-a"] "/tmp/site#nixosConfigurations.vm-a.config.system.build.toplevel"]
          ["utm create-image external flake" @[hey-bin "-!" "utm" "create-image" "--vm" "vm-a" "--flake" "/tmp/site#vm-a" "--force" "--yes"] "/tmp/site#nixosConfigurations.vm-a.config.system.build.images.qemu-efi"]]
        failure-commands @[
          ["utm create-image unknown phase" @[hey-bin "-!" "utm" "create-image" "--vm" "utm" "--flake" ".#utm" "--phases" "bad"] "Unknown UTM create-image phase: bad"]]]
    (var ok true)
    (each [label args] commands
      (unless (check-command label args)
        (set ok false)))
    (each [label args & needles] output-commands
      (unless (check-command-output-contains label args ;needles)
        (set ok false)))
    (each [label args & needles] failure-commands
      (unless (check-command-fails-output-contains label args ;needles)
        (set ok false)))
    (unless ok
      (exit 1))))
