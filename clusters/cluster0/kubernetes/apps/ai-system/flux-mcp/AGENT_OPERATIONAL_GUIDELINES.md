# Agent Operational Guidelines

This document outlines technical constraints and best practices for AI agents interacting with this repository and its associated MCP (Model Context Protocol) tools.

## Tool Usage Standards

To ensure reliability and prevent execution errors, all agents must adhere to the following:

### 1. Strict Tool Schema Adherence
* **No Invalid Arguments:** Never include arguments in a tool call that are not explicitly defined in its JSON schema. 
* **`invoke_agent` Specifics:** The `session_id` is a **returned value** from a successful agent invocation and is used for follow-up calls. It is **NOT** a valid input parameter for the initial `invoke_agent` request. Including it in a request will cause a validation error.

### 2. Error Handling and Recovery
* **Immediate Correction:** If a tool returns a validation error (e.g., `unexpected additional properties`), agents should immediately analyze the error, correct the call according to the tool's schema, and retry.
* **Avoid Loops:** If a specific tool or sub-agent consistently fails, do not repeatedly attempt the same incorrect call.

### 3. Strategic Tool Selection (Hybrid Approach)
* **Direct vs. Delegated:** While specialized agents (like `k8s-agent` or `flux-agent`) are powerful, they are subject to network and inference constraints.
* **Fallback to Primary Tools:** If a sub-agent is unresponsive, returns inconsistent data, or fails to locate files that are known to exist, agents should pivot to using direct file and search tools (`read_file`, `grep`, `find_path`, `list_directory`) to gather context manually.
* **Verification:** Always prioritize verifying the existence of a file via `list_directory` or `find_path` before attempting to read or edit it, rather than assuming a path from a sub-agent's response.

## GitOps Principles
Agents must remember that this is a Flux-managed repository. All changes to the cluster state must be implemented by modifying the manifests in Git, not by executing `kubectl` commands directly.
