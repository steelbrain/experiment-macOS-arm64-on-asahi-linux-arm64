#!/usr/bin/env python3
"""Send QMP commands to a QEMU QMP socket and print the answers.

usage: qmp.py SOCKET 'JSON command' ...
       qmp.py SOCKET --hmp 'info registers' ...   (each argument after --hmp is an HMP command)
"""
import json
import socket
import sys


def main() -> int:
    if len(sys.argv) < 3:
        print(__doc__, file=sys.stderr)
        return 2
    s = socket.socket(socket.AF_UNIX)
    s.settimeout(30)
    s.connect(sys.argv[1])
    f = s.makefile("rw")
    f.readline()

    def run(cmd):
        f.write(json.dumps(cmd) + "\n")
        f.flush()
        while True:
            line = f.readline()
            if not line:
                return {"error": "closed"}
            r = json.loads(line)
            if "return" in r or "error" in r:
                return r

    run({"execute": "qmp_capabilities"})
    args = sys.argv[2:]
    hmp = False
    rc = 0
    for a in args:
        if a == "--hmp":
            hmp = True
            continue
        cmd = {"execute": "human-monitor-command", "arguments": {"command-line": a}} if hmp else json.loads(a)
        r = run(cmd)
        if hmp and "return" in r:
            print(r["return"], end="")
        else:
            print(json.dumps(r))
        if "error" in r:
            rc = 1
    return rc


if __name__ == "__main__":
    sys.exit(main())
