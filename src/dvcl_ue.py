"""dvcl_ue.py - runs a Python file inside the open Unreal editor of a workspace (Unreal's Python
remote execution, which the project must have on: Project Settings > Python > Enable Remote Execution).

Usage: python dvcl_ue.py <engine dir> <workspace dir> <file.py> [timeout_s]
Prints the editor's output, then one line "RESULT ok|fail <text>".
Exit 0 ok, 2 no editor for this workspace, 3 the command failed, 4 bad setup."""
import os
import sys
import time


def main():
    if len(sys.argv) < 4:
        print("RESULT fail usage: dvcl_ue.py <engine dir> <workspace dir> <file.py> [timeout_s]")
        return 4
    engine, workspace, path = sys.argv[1], sys.argv[2], sys.argv[3]
    wait = float(sys.argv[4]) if len(sys.argv) > 4 else 8.0
    rx = os.path.join(engine, "Engine", "Plugins", "Experimental", "PythonScriptPlugin", "Content", "Python")
    if not os.path.isfile(os.path.join(rx, "remote_execution.py")):
        print("RESULT fail no remote_execution.py under " + rx)
        return 4
    sys.path.insert(0, rx)
    import remote_execution as rex

    ws = os.path.normcase(os.path.abspath(workspace)).rstrip("\\/")
    rem = rex.RemoteExecution(rex.RemoteExecutionConfig())
    rem.start()
    node = None
    t0 = time.time()
    try:
        # the editor whose project lives in this workspace
        while time.time() - t0 < wait and not node:
            for n in rem.remote_nodes:
                root = os.path.normcase(os.path.abspath(n.get("project_root", "") or "")).rstrip("\\/")
                if root and (root == ws or root.startswith(ws + os.sep)):
                    node = n
            if not node:
                time.sleep(0.25)
        if not node:
            print("RESULT fail no Unreal editor with remote execution for this workspace (nodes: %s)"
                  % [n.get("project_name") for n in rem.remote_nodes])
            return 2
        rem.open_command_connection(node["node_id"])
        code = open(path, encoding="utf-8").read()
        res = rem.run_command(code, unattended=True, exec_mode=rex.MODE_EXEC_FILE, raise_on_failure=False)
        for o in res.get("output", []):
            print(o.get("output", "").rstrip())
        print("RESULT %s %s" % ("ok" if res.get("success") else "fail", res.get("result", "")))
        return 0 if res.get("success") else 3
    finally:
        rem.stop()


if __name__ == "__main__":
    sys.exit(main())
