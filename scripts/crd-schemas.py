#!/usr/bin/env python3
"""Turn CustomResourceDefinition YAMLs into kubeconform JSON schemas.

Usage: scripts/crd-schemas.py <out-dir> <crd.yaml|dir>...
Writes <out-dir>/<group>/<kind>_<version>.json (kind lower-cased), the layout kubeconform's
-schema-location '<out-dir>/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' expects.
Objects with declared properties are made strict (additionalProperties: false) unless the CRD
preserves unknown fields. Needs PyYAML.
"""
import glob
import json
import os
import sys

import yaml


def strict(node):
    if isinstance(node, dict):
        if (node.get("type") == "object" and "properties" in node and "additionalProperties" not in node
                and not node.get("x-kubernetes-preserve-unknown-fields")):
            node["additionalProperties"] = False
        for v in node.values():
            strict(v)
    elif isinstance(node, list):
        for v in node:
            strict(v)


def main(out, inputs):
    files = []
    for i in inputs:
        files += sorted(glob.glob(os.path.join(i, "*.yaml"))) if os.path.isdir(i) else [i]
    n = 0
    for f in files:
        for doc in yaml.safe_load_all(open(f)):
            if not doc or doc.get("kind") != "CustomResourceDefinition":
                continue
            group, kind = doc["spec"]["group"], doc["spec"]["names"]["kind"].lower()
            for v in doc["spec"]["versions"]:
                schema = v.get("schema", {}).get("openAPIV3Schema")
                if not schema:
                    continue
                strict(schema)
                os.makedirs(os.path.join(out, group), exist_ok=True)
                with open(os.path.join(out, group, f"{kind}_{v['name']}.json"), "w") as fh:
                    json.dump(schema, fh)
                n += 1
    print(f"wrote {n} schemas to {out}")


if __name__ == "__main__":
    if len(sys.argv) < 3:
        print(__doc__)
        sys.exit(2)
    main(sys.argv[1], sys.argv[2:])
