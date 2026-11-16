#!/usr/bin/env python3
"""MCP end-to-end driver for the `mcp` check (docs/design/mcp.md).

`driver.py --suite NAME …` runs `suite_NAME.py` from this folder. A suite with
`suite(args)` runs in this process and gets every argument below; one without
(a self-contained script such as suite_shim.py) is run as its own program with
`--shim` and `--profile`. Prints one PASS/FAIL line per assertion and a final
`DRIVER passed=` summary.

Other tools import this file for its `MCP` client (from common.py).
"""

import argparse
import importlib.util
import os
import subprocess
import sys
import traceback

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

import common  # noqa: E402
from common import MCP  # noqa: E402,F401  (re-exported for importers)


def load(name):
    path = os.path.join(HERE, "suite_%s.py" % name)
    if not os.path.isfile(path):
        raise RuntimeError("no suite %r (%s)" % (name, path))
    spec = importlib.util.spec_from_file_location("suite_" + name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return path, module


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--suite", required=True)
    parser.add_argument("--shim", required=True)
    parser.add_argument("--profile", required=True)
    parser.add_argument("--events")
    parser.add_argument("--file")
    parser.add_argument("--link", default="https://example.com/mcp")
    parser.add_argument("--control", help="the app's --debug-control folder (setup verbs)")
    args = parser.parse_args()

    path, module = load(args.suite)
    if not hasattr(module, "suite"):
        return subprocess.call([sys.executable, path,
                                "--shim", args.shim, "--profile", args.profile])
    module.suite(args)
    if common.ANSWERS_CHECKED:
        # MCP-5: check_answer printed a FAIL naming each answer that broke its
        # schema or its text mirror; this line sums them up.
        common.report(common.ANSWERS_BROKEN == 0,
                      "[MCP-5] MCP the %s suite's %d answers match their outputSchema and text mirror (%d broke)"
                      % (args.suite, common.ANSWERS_CHECKED, common.ANSWERS_BROKEN))
    print("DRIVER passed=%d failed=%d" % (common.PASSED, common.FAILED))
    return 1 if common.FAILED else 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as error:  # one clear line, then the shell fails the check
        traceback.print_exc()
        print("FAIL " + str(error))
        sys.exit(1)
