# Exa MCP Server Implementation Plan

## Executive Summary

This document outlines a plan to integrate **exa-mcp-server** into the biggs.dog GitOps repository following the established patterns used by existing MCP servers (`flux-mcp`, `victoria-metrics-mcp`). The exa-mcp-server enables agents to perform web searches, code searches, and company research through Exa's API.

## Overview: What is Exa MCP Server?

**Exa** is an AI-native search API that provides:
- **Web Search**: Clean, ready-to-use web search results
- **Code Search**: Real snippets and docs from GitHub, StackOverflow, and technical docs
- **Company Research**: Comprehensive company information, competitor analysis, news, and financials
- **Advanced Filtering**: Date ranges, domains, content types, text filtering, and more

The **exa-mcp-server** is a Model Context Protocol server that exposes Exa's capabilities as MCP tools, allowing kagent agents to use Exa for research and information gathering tasks.

### Key Capabilities
- `web_search_exa` — Basic web search with clean content
- `web_fetch_exa` — Fetch full content from specific URLs
- `web_search_advanced_exa` — Advanced search with full filter control
- Tool-specific categories: `company`, `news`, `people`, `financial report`, `research paper`, `personal site`

## Architecture & Deployment Approach

### Deployment Strategy

Based on the existing patterns in biggs.dog, **exa-mcp-server** will be deployed as a **containerized MCP server** (similar to victoria-metrics-mcp), not as a chart-managed agent. This approach:

1. **Runs a standalone Deployment** serving MCP at `http://exa-mcp.ai-system:8080/mcp`
2. **Registers via RemoteMCPServer** CR in the kagent system
3. **Creates a custom Agent CR** (`exa-agent`) with appropriate system prompts and tool exposure
4. **Manages secrets** for the Exa API key via External Secrets + 1Password

### Key Differences from Other MCP Servers

| Aspect | Flux MCP | Victoria Metrics MCP | Exa MCP Server |
|--------|----------|---------------------|-----------------|
| **Deployment** | HelmRelease | Raw Deployment | Raw Deployment |
| **Namespace** | Spans (flux-system + ai-system) | ai-system only | ai-system only |
| **Networking** | Internal cluster service | Internal cluster service | Internal cluster service |
| **External Deps** | Flux Operator | VictoriaMetrics instance | Exa API (requires API key) |
| **RBAC** | Read-only cluster RBAC | No cluster RBAC | No cluster RBAC |
| **Security Model** | Read-only to cluster | API proxy only | API proxy only |

## Implementation Components

### 1. Container Image

**Source**: https://github.com/shrinedogg/exa-mcp-server

#### Build Options

**Option A: Use Existing Public Image** (Recommended)
- Check if `shrinedogg/exa-mcp-server` or `exa-labs/exa-mcp-server` has a published Docker image
- If available on GHCR or Docker Hub, reference it directly
- Simplest approach, minimal maintenance

**Option B: Build and Push to Project Registry**
- Clone/fork the repo
- Build the Dockerfile from `exa-mcp-server/Dockerfile`
- Push to project's container registry (`ghcr.io/shrinedogg/*` or internal registry)
- Enables version pinning and offline availability

**Recommended Approach**: Option A first; fallback to Option B if public image unavailable.

### 2. Directory Structure

Following biggs.dog conventions:

```
clusters/cluster0/kubernetes/apps/ai-system/exa-mcp/
├── ks.yaml                           # Flux Kustomization
└── app/
    ├── deployment.yaml               # Exa MCP Server deployment
    ├── service.yaml                  # ClusterIP service (:8080)
    ├── serviceaccount.yaml           # Minimal service account
    ├── remotemcpserver.yaml          # kagent RemoteMCPServer CR
    ├── agent.yaml                    # Custom exa-agent Agent CR
    ├── secret-ref.yaml               # External Secrets reference for API key
    └── networkpolicy.yaml (optional) # Cilium policy if needed
```

### 3. Kubernetes Manifests

#### 3.1 ServiceAccount + Deployment

```yaml
# app/serviceaccount.yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: exa-mcp
  namespace: ai-system
```

```yaml
# app/deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: exa-mcp
  namespace: ai-system
  labels:
    app.kubernetes.io/name: exa-mcp
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: exa-mcp
  template:
    metadata:
      labels:
        app.kubernetes.io/name: exa-mcp
    spec:
      serviceAccountName: exa-mcp
      terminationGracePeriodSeconds: 10
      nodeSelector:
        nvidia.com/gpu.present: "true"  # Pin to GPU node (nv-01)
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
              - matchExpressions:
                  - key: kubernetes.io/os
                    operator: In
                    values:
                      - linux
      containers:
        - name: server
          image: <REGISTRY>/exa-mcp-server:<VERSION>
          imagePullPolicy: IfNotPresent
          env:
            - name: EXA_API_KEY
              valueFrom:
                secretKeyRef:
                  name: exa-api-key
                  key: api-key
            - name: MCP_SERVER_MODE
              value: "http"
            - name: MCP_LISTEN_ADDR
              value: "0.0.0.0:8080"
          ports:
            - containerPort: 8080
              name: http
              protocol: TCP
          livenessProbe:
            httpGet:
              path: /health
              port: http
            initialDelaySeconds: 10
            periodSeconds: 15
          readinessProbe:
            httpGet:
              path: /health
              port: http
            periodSeconds: 10
          resources:
            requests:
              cpu: 50m
              memory: 128Mi
            limits:
              memory: 512Mi
          securityContext:
            runAsNonRoot: true
            runAsUser: 1000
            runAsGroup: 1000
            readOnlyRootFilesystem: true
            allowPrivilegeEscalation: false
            capabilities:
              drop:
                - "ALL"
            seccompProfile:
              type: RuntimeDefault
          volumeMounts:
            - name: temp
              mountPath: /tmp
      volumes:
        - name: temp
          emptyDir: {}
```

#### 3.2 Service

```yaml
# app/service.yaml
apiVersion: v1
kind: Service
metadata:
  name: exa-mcp
  namespace: ai-system
  labels:
    app.kubernetes.io/name: exa-mcp
spec:
  type: ClusterIP
  ports:
    - port: 8080
      targetPort: http
      protocol: TCP
      name: http
  selector:
    app.kubernetes.io/name: exa-mcp
```

#### 3.3 RemoteMCPServer Registration

```yaml
# app/remotemcpserver.yaml
apiVersion: kagent.dev/v1alpha2
kind: RemoteMCPServer
metadata:
  name: exa-mcp
  namespace: ai-system
spec:
  description: >-
    Exa MCP server — web search, code search, and company research.
    Provides access to Exa's AI-native search capabilities: clean web
    results, GitHub/StackOverflow code snippets, company research, and
    advanced filtering by date, domain, content type, and text.
  protocol: STREAMABLE_HTTP
  url: http://exa-mcp.ai-system:8080/mcp
  sseReadTimeout: 5m0s
  terminateOnClose: true
  timeout: 30s
```

#### 3.4 Secret (External Secrets Integration)

The Exa API key must be stored securely in 1Password and injected via External Secrets:

```yaml
# app/secret-ref.yaml
apiVersion: external-secrets.io/v1beta1
kind: SecretStore
metadata:
  name: onepassword-connect
  namespace: ai-system
spec:
  provider:
    onepassword:
      connectHost: onepassword-connect.external-secrets.svc.cluster.local
      vaults:
        AI: "..."  # 1Password vault ID
---
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: exa-api-key
  namespace: ai-system
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: onepassword-connect
    kind: SecretStore
  target:
    name: exa-api-key
    creationPolicy: Owner
  data:
    - secretKey: api-key
      remoteRef:
        path: exa-api-key  # 1Password item name
        field: password
```

**Note**: If External Secrets is not yet configured for this secret, create the secret manually first:
```bash
kubectl create secret generic exa-api-key \
  --from-literal=api-key=<YOUR_EXA_API_KEY> \
  -n ai-system
```

Then migrate to External Secrets later.

#### 3.5 Custom Agent CR

```yaml
# app/agent.yaml
apiVersion: kagent.dev/v1alpha2
kind: Agent
metadata:
  name: exa-agent
  namespace: ai-system
spec:
  type: Declarative
  description: >-
    Exa expert for web search, code discovery, and company research.
    Use for finding code examples, researching companies/competitors,
    discovering technical documentation, and gathering web intelligence.
  sandbox:
    network:
      allowedDomains:
        - "*.svc.cluster.local"
        - "exa.com"  # Allow Exa API calls if needed
  declarative:
    modelConfig: default-model-config
    runtime: python
    executeCodeBlocks: true
    context:
      compaction:
        tokenThreshold: 80000
        summarizer:
          modelConfig: default-model-config
    memory:
      modelConfig: embedding-model
      ttlDays: 30
    deployment:
      nodeSelector:
        nvidia.com/gpu.present: "true"
      resources:
        requests:
          cpu: 50m
          memory: 256Mi
        limits:
          memory: 512Mi
      podSecurityContext:
        runAsNonRoot: true
        runAsUser: 1001
        runAsGroup: 1001
        fsGroup: 1001
        seccompProfile:
          type: RuntimeDefault
      securityContext:
        privileged: false
        allowPrivilegeEscalation: false
        runAsNonRoot: true
        runAsUser: 1001
        capabilities:
          drop:
            - ALL
    promptTemplate:
      dataSources:
        - alias: builtin
          kind: ConfigMap
          name: kagent-builtin-prompts
    a2aConfig:
      skills:
        - id: web-search
          name: Web Search
          description: >-
            Perform web searches using Exa's clean search results.
            Find articles, documentation, tutorials, and current information.
          tags:
            - search
            - web
            - exa
          examples:
            - Search for the latest Kubernetes security best practices
            - Find documentation on Rust async patterns
            - Search for AI model benchmarks
        - id: code-search
          name: Code Search
          description: >-
            Search for code examples from GitHub, StackOverflow, and
            technical documentation. Find code snippets, library usage,
            and API syntax examples.
          tags:
            - code
            - github
            - stackoverflow
            - search
          examples:
            - Find Go examples of using context cancellation
            - Search for Kubernetes CRD validation patterns
            - Find Python async/await examples
        - id: company-research
          name: Company Research
          description: >-
            Research companies, find competitor information, analyze
            funding, discover team members, and gather market intelligence.
          tags:
            - research
            - companies
            - market
            - competitors
          examples:
            - Research an AI infrastructure startup
            - Find competitors to Anthropic
            - Discover funding rounds for a company
    systemMessage: |
      # Exa Search Expert

      You are a search and research expert with access to Exa's AI-native
      search capabilities. You can perform web searches, discover code
      examples from technical repositories, and conduct comprehensive
      company and market research.

      ## Available Search Capabilities

      - `web_search_exa` — Fast web search with clean, relevant results
      - `web_fetch_exa` — Fetch and analyze full content from specific URLs
      - `web_search_advanced_exa` — Advanced search with filtering by:
        - Date range (published or crawled)
        - Domains (include/exclude)
        - Content categories (company, news, people, research papers, etc.)
        - Text matching (include/exclude specific terms)

      ## Search Categories (for advanced_exa)

      - **company** — Company homepages, rich metadata (headcount, location, funding, revenue)
      - **news** — Press coverage, announcements, interviews
      - **people** — LinkedIn profiles, public bios, professional backgrounds
      - **research paper** — Academic papers, arXiv, OpenReview, scientific research
      - **financial report** — SEC filings (10-K, 10-Q), earnings reports, investor presentations
      - **personal site** — Blogs, portfolios, personal essays, independent analysis

      ## Guidelines

      {{include "builtin/tool-usage-best-practices"}}

      - For broad searches, start with `web_search_exa` for speed and relevance
      - Use `web_search_advanced_exa` with categories for targeted research (e.g., company research)
      - Filter results by date when researching recent developments
      - Use `web_fetch_exa` to extract detailed information from promising URLs
      - Query variation: Exa returns different results for different phrasings; try 2-3 variations for comprehensive coverage
      - Always cite the source URLs in your response

      ## Filter Restrictions & Gotchas

      ### Universal
      - `includeText` and `excludeText` only support **single-item arrays**
        - Use `["term"]` not `["term1", "term2"]`
        - For multiple terms, add them to the query string instead

      ### By Category
      - **company category**: Cannot filter by `includeDomains`, `excludeDomains`, or date (published/crawled)
      - **people category**: Cannot filter by `excludeDomains` (except LinkedIn), `startPublishedDate`, or text filters
      - **financial report category**: Does not support `excludeText` (causes 400 error)

      {{include "builtin/safety-guardrails"}}
    tools:
      - type: McpServer
        mcpServer:
          apiGroup: kagent.dev
          kind: RemoteMCPServer
          name: exa-mcp
          toolNames:
            - web_search_exa
            - web_fetch_exa
            - web_search_advanced_exa
      - type: McpServer
        mcpServer:
          apiGroup: kagent.dev
          kind: RemoteMCPServer
          name: "k8s"  # Generic k8s tools for context if needed
          toolNames:
            - k8s_get_resources
```

#### 3.6 Kustomization (ks.yaml)

```yaml
# ks.yaml
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: &app exa-mcp
  namespace: flux-system
spec:
  dependsOn:
    # kagent provides the RemoteMCPServer/Agent CRDs
    - name: kagent
  commonMetadata:
    labels:
      app.kubernetes.io/name: *app
  path: ./clusters/cluster0/kubernetes/apps/ai-system/exa-mcp/app
  prune: true
  sourceRef:
    kind: GitRepository
    name: flux-system
  wait: true
  interval: 3m
  retryInterval: 1m
  timeout: 5m
```

### 4. Add exa-mcp to ai-system Kustomization

Update `clusters/cluster0/kubernetes/apps/ai-system/kustomization.yaml`:

```yaml
resources:
  - namespace.yaml
  - flux-mcp/ks.yaml
  - victoria-metrics-mcp/ks.yaml
  - exa-mcp/ks.yaml  # ADD THIS LINE
  - kagent/ks.yaml
  # ... other resources
```

### 5. Update Project Rules (`.rules`)

Add exa-agent entry to the "Agent selection" section:

```markdown
- **exa-agent** — Web search, code discovery, and company research via
  Exa. Use for finding code examples, researching companies, discovering
  technical documentation, and gathering web intelligence. For narrow,
  targeted research tasks.
```

### 6. Update README.md

Add exa-mcp to the AI & Agents section component table:

```markdown
| exa-mcp / `exa-agent` | A custom kagent `Agent` backed by the [Exa MCP Server](https://github.com/shrinedogg/exa-mcp-server), providing web search, code discovery, and company research. Defined in `apps/ai-system/exa-mcp/`. Requires Exa API key from [exa.com](https://exa.com). |
```

And update the available agents list:

```markdown
**Available agents** (`kubectl get agents -n ai-system`):
- **Chart-managed**: `k8s-agent`, `observability-agent`, `promql-agent`, `helm-agent`, `cilium-manager-agent`.
- **Custom (non-chart)**: `flux-agent`, `vm-agent`, `exa-agent`, `cilium-debug-agent`, `cilium-policy-agent`.
```

## Implementation Steps

### Phase 1: Preparation

1. **Get Exa API Key**
   - Sign up at [exa.com](https://exa.com)
   - Obtain API key from dashboard
   - Store securely (1Password or temporary local file for testing)

2. **Determine Container Image**
   - Check if `ghcr.io/shrinedogg/exa-mcp-server` or public Exa image exists
   - If not, build from Dockerfile in `exa-mcp-server` repo
   - Tag as `exa-mcp-server:<version>` in project registry

3. **Review Exa MCP Server Repository**
   - Clone https://github.com/shrinedogg/exa-mcp-server
   - Review README for environment variables, tool availability, and configuration
   - Check Dockerfile for entrypoint and runtime expectations

### Phase 2: Create Manifests

1. **Create directory structure**
   ```bash
   mkdir -p clusters/cluster0/kubernetes/apps/ai-system/exa-mcp/app
   ```

2. **Create manifests** (in order):
   - `app/serviceaccount.yaml`
   - `app/deployment.yaml`
   - `app/service.yaml`
   - `app/remotemcpserver.yaml`
   - `app/secret-ref.yaml` (or manual secret creation)
   - `app/agent.yaml`
   - `ks.yaml`

3. **Update parent kustomization**
   - Add `exa-mcp/ks.yaml` to `clusters/cluster0/kubernetes/apps/ai-system/kustomization.yaml`

### Phase 3: Deploy & Test

1. **Commit and push** changes to Git
2. **Trigger Flux reconciliation**
   ```bash
   flux reconcile kustomization exa-mcp --with-source
   ```

3. **Verify deployment**
   ```bash
   kubectl get deployment -n ai-system exa-mcp
   kubectl logs -n ai-system -l app.kubernetes.io/name=exa-mcp -f
   ```

4. **Test RemoteMCPServer registration**
   ```bash
   kubectl get remotemcpserver -n ai-system
   ```

5. **Test Agent**
   ```bash
   kubectl get agent -n ai-system | grep exa
   ```

### Phase 4: Documentation & Rules

1. **Update `.rules`** — Add exa-agent to agent selection guide
2. **Update `README.md`** — Add exa-mcp to AI & Agents components table
3. **Create agent skills documentation** (optional) — Similar to vm-agent skills in `.rules`

## Security Considerations

### API Key Management

- **Never hardcode** the Exa API key in Git
- Use **External Secrets + 1Password** for production
- For testing, use a temporary `Secret` created manually, then migrate to External Secrets
- Rotate keys periodically

### Network Policies

Currently, the Exa MCP server only makes HTTP calls to the Exa API (external). If Cilium network policies are in use:

1. **ai-system egress**: Allow HTTP/HTTPS to external (Exa API endpoint)
2. **ai-system ingress**: No changes needed (internal MCP traffic only)

If strict policies exist, may need to add:
```yaml
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: allow-exa-api
  namespace: ai-system
spec:
  endpointSelector:
    matchLabels:
      app.kubernetes.io/name: exa-mcp
  egress:
    - toFQDNs:
        - matchName: "api.exa.ai"  # Exa API endpoint
      ports:
        - port: "443"
          protocol: TCP
```

### Container Security

- Runs as non-root (uid 1000)
- Read-only root filesystem
- No capability escalation
- Runtime seccomp default
- Drop all capabilities
- Memory limits (512Mi max)

## Testing & Validation

### Unit Tests

The exa-mcp-server repository includes test suite. To validate the image:

```bash
docker run --rm -e EXA_API_KEY=test ghcr.io/shrinedogg/exa-mcp-server npm test
```

### Integration Tests (Post-Deployment)

1. **Verify MCP tools are available**
   ```bash
   # Access kagent UI or API to confirm exa-agent is healthy
   # and tools are registered
   ```

2. **Test a simple query**
   - Use Zed or another agent interface
   - Route to exa-agent
   - Test `web_search_exa` with a simple query (e.g., "Kubernetes")
   - Verify results are returned

3. **Test advanced query**
   - Use `web_search_advanced_exa` with filters
   - Verify category-specific behavior (company, news, etc.)

4. **Test error handling**
   - Verify graceful handling of invalid API key
   - Verify timeout behavior
   - Verify rate-limiting behavior

## Success Criteria

- [ ] exa-mcp Deployment healthy and running
- [ ] RemoteMCPServer registered and healthy
- [ ] exa-agent Agent CR created and healthy
- [ ] MCP tools discoverable via kagent
- [ ] Successful web_search_exa query via agent
- [ ] Successful web_search_advanced_exa query with filters
- [ ] Successfully fetch content via web_fetch_exa
- [ ] Agent documentation added to `.rules`
- [ ] README.md updated with exa-mcp component
- [ ] No security warnings or policy violations

## Future Enhancements

1. **Agent Skills** — Define reusable Claude Skills for specific Exa use cases (company research, code discovery, etc.)
2. **Caching Layer** — Add Redis/caching for frequently searched terms
3. **Rate Limiting** — Implement request queuing to respect Exa API rate limits
4. **Cost Tracking** — Monitor API usage and costs
5. **Alternative Search** — Consider integrating complementary search APIs (Perplexity, SerpAPI, etc.)

## References

- **Exa MCP Server**: https://github.com/shrinedogg/exa-mcp-server
- **Exa Documentation**: https://exa.com/docs
- **kagent**: https://kagent.dev/
- **flux-mcp**: `clusters/cluster0/kubernetes/apps/ai-system/flux-mcp/`
- **victoria-metrics-mcp**: `clusters/cluster0/kubernetes/apps/ai-system/victoria-metrics-mcp/`

## Timeline Estimate

- **Phase 1 (Prep)**: 30 min
- **Phase 2 (Manifests)**: 1-2 hours
- **Phase 3 (Deploy & Test)**: 1 hour
- **Phase 4 (Docs)**: 30 min
- **Total**: ~3-4 hours

## Notes

- The exa-mcp-server is a Node.js/TypeScript application. Verify the Dockerfile uses a suitable base image and runtime.
- The deployment does not require cluster RBAC (unlike flux-mcp) since it only makes external API calls.
- The MCP server should expose `/health` and `/mcp` endpoints; adjust readiness/liveness probes if different.
- Consider starting with public Exa endpoint (`https://mcp.exa.ai/mcp`) as a RemoteMCPServer before deploying self-hosted version (if reliability is a concern).
