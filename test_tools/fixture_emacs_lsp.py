"""Synthetic local-only stdio LSP fixture. Logs method names, never content."""
import json
import sys
from pathlib import Path
log = Path(sys.argv[1])
column = int(sys.argv[2]) if len(sys.argv) > 2 else 1
if column not in (0, 1):
    raise SystemExit("Synthetic diagnostic column must be 0 or 1")
def send(value):
    body=json.dumps(value,separators=(",", ":")).encode()
    sys.stdout.buffer.write(f"Content-Length: {len(body)}\r\n\r\n".encode()+body)
    sys.stdout.buffer.flush()
while True:
    headers={}
    while True:
        line=sys.stdin.buffer.readline()
        if not line: raise SystemExit(0)
        if line in (b"\r\n",b"\n"): break
        key,value=line.decode().split(":",1);headers[key.lower()]=value.strip()
    value=json.loads(sys.stdin.buffer.read(int(headers["content-length"])))
    method=value.get("method")
    if method:
        with log.open("a") as output: output.write(method+"\n")
    if method=="initialize":
        result={"capabilities":{"textDocumentSync":1,"diagnosticProvider":{"interFileDependencies":False,"workspaceDiagnostics":False}},"serverInfo":{"name":"nixi-synthetic-fixture","version":"1"}}
    elif method=="textDocument/diagnostic":
        result={"kind":"full","items":[{"range":{"start":{"line":0,"character":column},"end":{"line":0,"character":column+1}},"severity":1,"source":"nixi-fixture","message":"synthetic diagnostic"}]}
    elif method=="shutdown": result=None
    else: result=None
    if "id" in value and method:
        send({"jsonrpc":"2.0","id":value["id"],"result":result})
    if method=="exit":raise SystemExit(0)
