#!/usr/bin/env python3
"""Opt-in local GNU TLS verification controls using disposable synthetic CAs."""
import argparse
import json
import re
from pathlib import Path
import socket
import ssl
import subprocess
import threading
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--emacs", type=Path, required=True)
parser.add_argument("--openssl", type=Path, required=True)
parser.add_argument("--source", required=True, help="Corrected gnutls.el or installed")
parser.add_argument("--baseline-source", type=Path, required=True)
parser.add_argument("--workdir", type=Path, required=True, help="New exclusive directory")
args = parser.parse_args()
for path in [args.emacs, args.openssl, args.baseline_source, args.workdir]:
    if not path.is_absolute():
        parser.error("Filesystem arguments must be absolute")
if args.source != "installed" and not Path(args.source).is_absolute():
    parser.error("Source must be an absolute filename or installed")
if not all(path.is_file() for path in [args.emacs, args.openssl, args.baseline_source]):
    parser.error("Interpreter, OpenSSL and baseline source must be existing local files")
if args.source != "installed" and not Path(args.source).is_file():
    parser.error("Corrected source must be an existing local file")
args.workdir.mkdir(mode=0o700)
root = args.workdir
certs = root / "certificates"
certs.mkdir(mode=0o700)
env = {"HOME": str(root), "PATH": "/usr/bin:/bin", "LANG": "C", "LC_ALL": "C",
       "TMPDIR": str(root)}
config = root / "openssl.cnf"
config.write_text("[req]\ndistinguished_name=dn\n[dn]\n")
env["OPENSSL_CONF"] = str(config)


def openssl(*command):
    completed = subprocess.run(
        [str(args.openssl), *command], env=env, cwd=root,
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=30)
    if completed.returncode:
        raise RuntimeError("Synthetic certificate generation failed: " + completed.stdout)


for label in ["root", "wrong"]:
    openssl("req", "-x509", "-newkey", "rsa:2048", "-noenc", "-days", "1",
            "-subj", "/CN=NixiSynthetic" + label,
            "-keyout", str(certs / (label + ".key")),
            "-out", str(certs / (label + ".pem")),
            "-addext", "basicConstraints=critical,CA:true",
            "-addext", "keyUsage=critical,keyCertSign,cRLSign")
    (certs / (label + ".key")).chmod(0o600)
openssl("req", "-new", "-newkey", "rsa:2048", "-noenc", "-subj", "/CN=localhost",
        "-keyout", str(root / "server.key"), "-out", str(root / "server.csr"))
(root / "server.key").chmod(0o600)
extensions = root / "server.ext"
extensions.write_text(
    "basicConstraints=critical,CA:false\n"
    "keyUsage=critical,digitalSignature,keyEncipherment\n"
    "extendedKeyUsage=serverAuth\n"
    "subjectAltName=DNS:localhost,IP:127.0.0.1\n")
openssl("x509", "-req", "-in", str(root / "server.csr"), "-CA", str(certs / "root.pem"),
        "-CAkey", str(certs / "root.key"), "-set_serial", "10", "-days", "1",
        "-extfile", str(extensions), "-out", str(root / "server.pem"))
probe = root / "tls-probe.el"
probe.write_text(r''';;; Synthetic loopback TLS proof -*- lexical-binding: t; -*-
(setq native-comp-jit-compilation nil native-comp-enable-subr-trampolines nil)
(require 'json)
(defvar source (pop command-line-args-left))
(defvar ca (pop command-line-args-left))
(defvar port (string-to-number (pop command-line-args-left)))
(if (equal source "installed") (require 'gnutls) (load source nil t t))
(setq gnutls-trustfiles nil gnutls-crlfiles nil)
(defun forbid-process (&rest _)
  (error "Subprocesses forbidden in local TLS fixture"))
(dolist (fn '(make-process call-process call-process-region process-file
              start-process start-file-process))
  (advice-add fn :override #'forbid-process))
(advice-add 'make-network-process :before
 (lambda (&rest options)
   (unless (and (equal (plist-get options :host) "127.0.0.1")
                (equal (plist-get options :service) port))
     (error "Only the exact synthetic loopback listener is allowed"))))
(let ((selected (gnutls--get-files (list ca))) process established problem reason)
  (unless (equal selected (list ca))
    (error "Synthetic CA filename was not selected exactly"))
  (unwind-protect
      (condition-case err
          (progn
            (setq process
                  (make-network-process :name "nixi-synthetic-tls"
                                        :host "127.0.0.1" :service port
                                        :family 'ipv4 :nowait nil :coding 'binary))
            (gnutls-negotiate :process process :hostname "localhost"
                             :type 'gnutls-x509pki :trustfiles selected
                             :verify-error t :verify-flags 0)
            (setq established t))
        (error (setq problem (symbol-name (car err))
                     reason (error-message-string err))))
    (when (process-live-p process) (delete-process process)))
  (princ (json-encode
          (list (cons 'tlsEstablished (if established t :json-false))
                (cons 'selectedExactly t) (cons 'errorSymbol problem)
                (cons 'rejectionReason reason)))))
''')
profiles = {
    "enumeration-denied":
        '(version 1)\n(allow default)\n(deny file-read-data (literal '
        + json.dumps(str(certs)) + '))\n',
    "ca-content-denied":
        '(version 1)\n(allow default)\n(deny file-read-data (literal '
        + json.dumps(str(certs)) + '))\n(deny file-read-data (literal '
        + json.dumps(str(certs / "root.pem")) + '))\n'
}
for name, value in profiles.items():
    (root / (name + ".sb")).write_text(value)
results = []
cases = [
    ("baseline-readable-ca", str(args.baseline_source), certs / "root.pem", None, True),
    ("literal-parent-denied-readable-ca", args.source, certs / "root.pem",
     "enumeration-denied", True),
    ("literal-parent-denied-wrong-ca", args.source, certs / "wrong.pem",
     "enumeration-denied", False),
    ("literal-parent-and-ca-content-denied", args.source, certs / "root.pem",
     "ca-content-denied", False),
]
for name, source, ca, profile, expected in cases:
    listener = socket.socket()
    listener.bind(("127.0.0.1", 0))
    listener.listen(1)
    listener.settimeout(10)
    port = listener.getsockname()[1]
    server_state = {}

    def serve():
        try:
            connection, _ = listener.accept()
            context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            context.load_cert_chain(str(root / "server.pem"), str(root / "server.key"))
            with connection:
                with context.wrap_socket(connection, server_side=True) as tls:
                    server_state["handshake"] = True
                    try:
                        tls.sendall(b"synthetic TLS fixture\n")
                    except (OSError, ssl.SSLError):
                        pass
        except (OSError, ssl.SSLError) as error:
            server_state["errorType"] = type(error).__name__
        finally:
            listener.close()

    thread = threading.Thread(target=serve, daemon=True)
    thread.start()
    command = ([] if profile is None else
               ["/usr/bin/sandbox-exec", "-f", str(root / (profile + ".sb"))])
    command += [str(args.emacs), "--batch", "--quick", "--no-site-file",
                "--load", str(probe), source, str(ca), str(port)]
    started = time.monotonic()
    try:
        completed = subprocess.run(
            command, env=env, cwd=root, text=True,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=20)
    finally:
        listener.close()
        thread.join(timeout=11)
    (root / (name + ".stdout")).write_text(completed.stdout)
    (root / (name + ".stderr")).write_text(completed.stderr)
    if completed.returncode:
        raise RuntimeError(name + " failed before TLS outcome: "
                           + completed.stdout + completed.stderr)
    outcome = json.loads(completed.stdout)
    passed = (outcome["selectedExactly"] and outcome["tlsEstablished"] is expected
              and not thread.is_alive())
    if name == "literal-parent-denied-wrong-ca":
        reason = outcome.get("rejectionReason") or ""
        match = re.fullmatch(
            r"Certificate validation failed localhost, verification code ([0-9a-fA-F]+)",
            reason)
        passed = (passed and outcome["errorSymbol"] == "error"
                  and match is not None and int(match.group(1), 16) != 0)
    if name == "literal-parent-and-ca-content-denied":
        passed = (passed and outcome["errorSymbol"] == "gnutls-error"
                  and (outcome.get("rejectionReason") or "").endswith(", -64"))
    results.append({
        "name": name, "expectedTlsEstablished": expected, "outcome": outcome,
        "status": "passed" if passed else "failed",
        "seconds": round(time.monotonic() - started, 2), "server": server_state})
    print(name, json.dumps(outcome), "passed=" + str(passed), flush=True)
report = {
    "scope": "Synthetic loopback TLS only; no external provider or consumer truststore",
    "openssl": subprocess.run(
        [str(args.openssl), "version"], env=env, capture_output=True,
        text=True, check=True).stdout.strip(),
    "pythonSsl": ssl.OPENSSL_VERSION,
    "results": results}
(root / "report.json").write_text(json.dumps(report, indent=2) + "\n")
raise SystemExit(0 if all(row["status"] == "passed" for row in results) else 1)
