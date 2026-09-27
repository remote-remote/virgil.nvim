"""Runs bin/virgil's validator and encoder over trail files, for test_contract.lua.

Prints one json object: {path: {"error": str | null, "encoded": str | null}}.
"""
import importlib.machinery
import importlib.util
import json
import os
import sys

here = os.path.dirname(os.path.abspath(__file__))
loader = importlib.machinery.SourceFileLoader("virgil_cli", os.path.join(here, "..", "bin", "virgil"))
spec = importlib.util.spec_from_loader("virgil_cli", loader)
cli = importlib.util.module_from_spec(spec)
loader.exec_module(cli)

out = {}
for path in sys.argv[1:]:
    with open(path, "r", encoding="utf-8") as fh:
        trail = json.load(fh)
    err = cli.validate_trail(trail)
    out[path] = {"error": err, "encoded": None if err else cli.encode_trail(trail)}
sys.stdout.write(json.dumps(out))
