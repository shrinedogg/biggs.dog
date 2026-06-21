#!/usr/bin/env python3
"""Helm post-renderer: add k8s tools to cilium agents."""
import sys
import yaml


def process(doc):
    if (
        isinstance(doc, dict)
        and doc.get("kind") == "Agent"
        and doc.get("namespace") == "ai-system"
    ):
        name = doc.get("metadata", {}).get("name", "")
        if name in ("cilium-debug-agent", "cilium-policy-agent"):
            tools = doc.get("spec", {}).get("declarative", {}).get("tools", [])
            for tool in tools:
                if tool.get("type") == "McpServer":
                    tool_names = tool.get("mcpServer", {}).get("toolNames", [])
                    added = False
                    for t in ["k8s_get_resources", "k8s_describe_resource"]:
                        if t not in tool_names:
                            tool_names.append(t)
                            added = True
                    if added:
                        print(
                            f"  + Added k8s tools to {name}: "
                            f"{', '.join(t for t in ['k8s_get_resources', 'k8s_describe_resource'] if t not in tool_names[:-2])}",
                            file=sys.stderr,
                        )
    return doc


def main():
    content = sys.stdin.read()
    docs = list(yaml.safe_load_all(content))
    result = [process(d) for d in docs if d is not None]
    yaml.dump_all(result, sys.stdout, default_flow_style=False)


if __name__ == "__main__":
    main()
