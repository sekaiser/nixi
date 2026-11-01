# Bounded, isolated Python parsers. Only explicit source-checkout tools are
# imported; packaged Hey supplies its pinned interpreter and YAML dependency.
(use hey)
(import ./process)

(defn- call-tool [module args]
  (def command @[(or (os/getenv "HEY_RUNTIME_PYTHON") "python3") "-I" "-c"
                 "import runpy,sys; directory,module=sys.argv[1:3]; sys.path.insert(0,directory); sys.argv=sys.argv[2:]; runpy.run_module(module,run_name='__main__')"
                 (path :framework "tools") module ;args])
  (with-envvars ["NIX_PYTHONPATH" nil "NIX_PYTHONEXECUTABLE" nil "NIX_PYTHONPREFIX" nil
                 "PYTHONEXECUTABLE" nil "PYTHONPATH" nil "PYTHONHOME" nil "__PYVENV_LAUNCHER__" nil]
    (let [result (process/probe command 6 (* 512 1024))]
      (unless (= 0 (result :status))
        (error (case module
                 "runtime_input" "Credential input must be a readable UTF-8 regular file of at most 64 KiB; reads are bounded"
                 "ssh_diagnostics" "SSH public material is unreadable, invalid or exceeds its input limits"
                 "Agent configuration is missing, unreadable, malformed or exceeds its input limits")))
      (json/decode (result :out) false true))))

(defn secret [file] (call-tool "runtime_input" [file]))
(defn agent-config [kind file expected]
  (call-tool "agent_config" [kind file (string (json/encode expected))]))
(defn ssh-certificate [kind file]
  (call-tool "ssh_diagnostics" [kind file]))
(defn ssh-trust [file config home]
  (call-tool "ssh_diagnostics" ["trust" file "--config" config "--home" home]))
