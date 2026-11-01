{lib}: value:
if builtins.match "[^[:cntrl:]]+" value == null
then throw "OpenSSH configuration paths must be nonempty and contain no control characters."
else "\"${lib.replaceStrings ["\\" "\""] ["\\\\" "\\\""] value}\""
