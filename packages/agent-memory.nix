{
  lib,
  python3,
  writeShellApplication,
  ...
}:
writeShellApplication {
  name = "nixi-agent-memory";
  text = ''
    exec ${python3}/bin/python3 -I ${../tools/agent_memory.py} "$@"
  '';
  meta = {
    description = "Qualified, on-demand Tencent MemoryCore MCP adapter";
    license = lib.licenses.mit;
    platforms = lib.platforms.unix;
  };
}
