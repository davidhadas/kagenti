# Remove Unimplemented Feature Flags — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Delete the `sandbox`, `triggers` and `integrations` feature flags, whose backend routers were never merged, along with every artifact that exists only to serve them.

**Architecture:** Four commits. Commit 1 hardens the four `ImportError` guards that stay (a logging-only change). Commits 2-4 are vertical slices — one per flag — each spanning backend, Helm chart, UI and deploy scripts, so no commit leaves a flag half-removed. The three UI deletion sets are disjoint (verified by import-graph analysis), which is what makes the per-flag split safe.

**Tech Stack:** FastAPI + pydantic v2 (backend), pytest, Helm 3 + helm-unittest v1.0.3, React + TypeScript + Vite, vitest, ESLint.

**Spec:** `docs/_internal/superpowers/specs/2026-09-14-remove-unimplemented-feature-flags-design.md`

## Global Constraints

- Repo: `/Users/cwiklik/dev/aiplatform/public/kagenti-fork/kagenti`, branch `fix/remove-unimplemented-flags-1764`.
- **Every commit uses `git commit -s`** (DCO sign-off is an enforced, blocking check).
- **Commit trailer is `Assisted-By: Claude (Anthropic AI) <noreply@anthropic.com>`** — house convention. Never `Co-Authored-By`.
- Conventional commit prefixes: `fix:`, `docs:`, `chore:`. Subject under 72 chars.
- **Never delete anything by filename match.** The live `agentSandbox` feature owns `SandboxWizard.tsx`, `SandboxConfig.tsx`, `SandboxAgentsPanel.tsx`, `workloadType.ts`. Only the enumerated paths in this plan get deleted.
- **`services/eventService.ts`, `sandboxService`, `modelsService`, `app/services/session_db.py` and `app/services/sidecar_manager.py` are never touched.** All are reachable from live code.
- Pre-existing dead code stays: the 7 orphaned UI files and `graphCardService` in `api.ts` are out of scope (spec §7, §4.5).
- Delete line ranges **bottom-up within a file** so earlier deletions don't shift later line numbers. All line numbers in this plan refer to the file's state at the start of its task.

**Verification commands** (used throughout):

```bash
# backend
cd rossoctl/backend && pytest -q
# chart
helm unittest charts/rossoctl
helm lint charts/rossoctl
# UI
cd rossoctl/ui-v2 && npm run typecheck && npm run lint && npm run test:unit && npm run build
```

---

### Task 1: Harden the four surviving ImportError guards

`main.py` has seven `try/except ImportError` guard blocks. Three guard modules that don't exist (removed in Tasks 2-4). The other four guard modules that **are** present (`skills.py`, `acp.py`, `simulation.py`, `dream.py`), and they discard the traceback — so a genuine `ImportError` *inside* one of those modules is misreported as "modules not installed". That information loss is what let issue #1764 survive to production.

**No unit test.** These guards execute at module-import time, so exercising them means re-importing `app.main` under a patched `settings` and a poisoned import hook — a fragile test with more moving parts than the one-keyword change it would cover. Verification is inspection plus the existing suite. This is a deliberate exception to the test-first default, not an oversight.

**Files:**
- Modify: `rossoctl/backend/app/main.py:110-152` (the `skills`, `acp`, `simulated_tools`, `dreaming` guard blocks)

**Interfaces:**
- Consumes: nothing.
- Produces: nothing. No signature changes; logging output only.

- [ ] **Step 1: Add `exc_info=True` to the `skills` guard**

Find this block (starts at line 110) and add the keyword argument:

```python
_skills_modules_loaded = False
if settings.rossoctl_feature_flag_skills:
    try:
        from app.routers import skills  # noqa: E402

        _skills_modules_loaded = True
    except ImportError:
        logging.getLogger(__name__).warning(
            "SKILLS flag enabled but skills modules not installed — skipping",
            exc_info=True,
        )
```

- [ ] **Step 2: Add `exc_info=True` to the `acp` guard**

```python
    except ImportError:
        logging.getLogger(__name__).warning(
            "ACP flag enabled but acp modules not installed — skipping",
            exc_info=True,
        )
```

- [ ] **Step 3: Add `exc_info=True` to the `simulated_tools` guard**

```python
    except ImportError:
        logging.getLogger(__name__).warning(
            "SIMULATED_TOOLS flag enabled but simulation modules not installed — skipping",
            exc_info=True,
        )
```

- [ ] **Step 4: Add `exc_info=True` to the `dreaming` guard**

```python
    except ImportError:
        logging.getLogger(__name__).warning(
            "DREAMING flag enabled but dreaming modules not installed — skipping",
            exc_info=True,
        )
```

- [ ] **Step 5: Confirm exactly four handlers changed, and that the three dead ones were left alone**

Run: `grep -c 'exc_info=True' rossoctl/backend/app/main.py`
Expected: `4`

Run: `grep -n 'exc_info=True' rossoctl/backend/app/main.py`
Expected: four line numbers, all greater than 109. If any is below 110 you have edited a guard that Tasks 2-4 delete — revert that one.

- [ ] **Step 6: Run the backend suite**

Run: `cd rossoctl/backend && pytest -q`
Expected: PASS, same count as before the change.

- [ ] **Step 7: Commit**

```bash
git add rossoctl/backend/app/main.py
git commit -s -m "fix(backend): log ImportError tracebacks on flagged router guards

The four guards whose modules are present (skills, acp, simulation, dream)
discarded the traceback, so a real ImportError inside one of those modules was
misreported as 'modules not installed'. That is the information loss that let
rossoctl#1764 reach production unnoticed.

Assisted-By: Claude (Anthropic AI) <noreply@anthropic.com>"
```

---

### Task 2: Remove the `sandbox` flag

The largest slice: 32 UI file deletions, 7 `api.ts` unit removals, 4 chart edits, 6 backend edits, 1 script edit, 1 barrel edit.

**Files:**
- Create: `rossoctl/backend/tests/test_removed_feature_flags.py`
- Modify: `rossoctl/backend/app/core/config.py:79`, `rossoctl/backend/app/routers/config.py:32,89`, `rossoctl/backend/app/main.py` (4 regions), `rossoctl/backend/tests/test_simulation_flag.py:24`
- Modify: `charts/rossoctl/values.yaml:10-13`, `charts/rossoctl/templates/ui.yaml` (4 regions), `charts/rossoctl/tests/ui_test.yaml`
- Modify: `scripts/openshell/deploy-shared.sh:1011-1012`, `CLAUDE.md:195`
- Modify: `rossoctl/ui-v2/src/hooks/useFeatureFlags.ts`, `src/App.tsx`, `src/components/AppLayout.tsx`, `src/services/api.ts`, `src/pages/index.ts:19`
- Delete: 32 files (Step 14)

**Interfaces:**
- Consumes: nothing from Task 1.
- Produces: `rossoctl/backend/tests/test_removed_feature_flags.py` with two functions, `test_removed_flags_absent_from_settings()` and `test_removed_flags_absent_from_response_model()`, each parametrised over a module-level tuple `REMOVED_FLAGS`. Tasks 3 and 4 extend that tuple rather than creating new files.

- [ ] **Step 1: Pin the PVC RBAC behaviour before touching it (regression guard)**

This is the highest-risk line in the whole change: `ui.yaml:502` gates PersistentVolumeClaim RBAC on `or sandbox simulatedTools`, and `simulatedTools` is a **live** feature. Write the guard first so the cut is provably safe.

Append to `charts/rossoctl/tests/ui_test.yaml`:

```yaml
  # rossoctl#1764: the PVC rule was gated on `or sandbox simulatedTools`.
  # Removing the sandbox flag must narrow that condition, not delete the rule —
  # the simulated-tools delete path (#2151) enumerates and tears down PVCs.
  - it: grants PVC permissions when simulatedTools is enabled
    set:
      featureFlags.simulatedTools: true
    documentSelector:
      path: metadata.name
      value: rossoctl-backend
    asserts:
      - isKind:
          of: ClusterRole
      - contains:
          path: rules
          content:
            apiGroups: [""]
            resources: ["persistentvolumeclaims"]
            verbs: ["get", "list", "create", "patch", "delete"]

  - it: withholds PVC permissions when no feature needing them is enabled
    documentSelector:
      path: metadata.name
      value: rossoctl-backend
    asserts:
      - isKind:
          of: ClusterRole
      - notContains:
          path: rules
          content:
            apiGroups: [""]
            resources: ["persistentvolumeclaims"]
            verbs: ["get", "list", "create", "patch", "delete"]
```

- [ ] **Step 2: Run the chart tests — both new cases must PASS already**

Run: `helm unittest charts/rossoctl`
Expected: PASS. These pin existing behaviour; they are a "pin before you cut" guard, not a red→green pair. If the first case fails now, stop — the template does not do what the spec says and the plan needs revisiting.

- [ ] **Step 3: Write the failing backend test**

Create `rossoctl/backend/tests/test_removed_feature_flags.py`:

```python
# Copyright 2025 IBM Corp.
# Licensed under the Apache License, Version 2.0

"""The sandbox/triggers/integrations flags were removed — their routers were
never merged, so enabling one produced a UI whose every API call 404'd.
See https://github.com/rossoctl/rossoctl/issues/1764.

These tests fail if a flag is reintroduced by a bad merge.
"""

import pytest

from app.core.config import Settings
from app.routers.config import FeatureFlagsResponse

# Extended by the triggers and integrations commits.
REMOVED_FLAGS = (("sandbox", "rossoctl_feature_flag_sandbox"),)

# Flags that must survive — guards against an over-broad removal.
LIVE_FLAGS = ("agentSandbox", "skills", "simulatedTools", "admin")


@pytest.mark.parametrize("_api_name,settings_name", REMOVED_FLAGS)
def test_removed_flags_absent_from_settings(_api_name: str, settings_name: str):
    assert settings_name not in Settings.model_fields


@pytest.mark.parametrize("api_name,_settings_name", REMOVED_FLAGS)
def test_removed_flags_absent_from_response_model(api_name: str, _settings_name: str):
    assert api_name not in FeatureFlagsResponse.model_fields


@pytest.mark.parametrize("api_name", LIVE_FLAGS)
def test_live_flags_still_present(api_name: str):
    assert api_name in FeatureFlagsResponse.model_fields
```

- [ ] **Step 4: Run it to verify it fails**

Run: `cd rossoctl/backend && pytest tests/test_removed_feature_flags.py -v`
Expected: the two `sandbox` cases FAIL (`assert 'rossoctl_feature_flag_sandbox' not in ...` and `assert 'sandbox' not in ...`); the four `test_live_flags_still_present` cases PASS.

- [ ] **Step 5: Remove the backend Settings field and response field**

In `rossoctl/backend/app/core/config.py`, delete line 79:

```python
    rossoctl_feature_flag_sandbox: bool = False
```

In `rossoctl/backend/app/routers/config.py`, delete line 32 from `FeatureFlagsResponse`:

```python
    sandbox: bool = Field(description="Interactive sandbox session UI (Legion)")
```

and delete line 89 from `get_feature_flags`:

```python
        sandbox=settings.rossoctl_feature_flag_sandbox,
```

- [ ] **Step 6: Run the test to verify it passes**

Run: `cd rossoctl/backend && pytest tests/test_removed_feature_flags.py -v`
Expected: all cases PASS.

- [ ] **Step 7: Remove the backend guard block, shutdown branch and router registrations**

Work bottom-up. In `rossoctl/backend/app/main.py`, delete lines **274-284**:

```python
if _sandbox_modules_loaded:
    app.include_router(sandbox.router, prefix="/api/v1")
    app.include_router(sandbox_deploy.router, prefix="/api/v1")
    app.include_router(sandbox_files.router, prefix="/api/v1")
    app.include_router(token_usage.router, prefix="/api/v1")
    app.include_router(sidecar.router, prefix="/api/v1")
    app.include_router(events.router, prefix="/api/v1")
    app.include_router(models.router, prefix="/api/v1")
    app.include_router(llm_keys.router, prefix="/api/v1")
    logger.info("Feature flag SANDBOX enabled — sandbox routes registered")
```

(plus the blank line that followed it)

Then delete lines **226-233**, the shutdown branch:

```python
    # Shutdown sandbox services (only if enabled and loaded)
    if _sandbox_modules_loaded:
        from app.services.sidecar_manager import get_sidecar_manager  # pylint: disable=import-error,no-name-in-module

        await get_sidecar_manager().shutdown()

        # Close session DB pools
        await close_all_pools()  # pylint: disable=used-before-assignment
```

Then delete lines **68-88**, the guard block:

```python
_sandbox_modules_loaded = False
if settings.rossoctl_feature_flag_sandbox:
    try:
        from app.routers import (  # noqa: E402
            sandbox,
            sandbox_deploy,
            sandbox_files,
            token_usage,
            sidecar,
            events,
            models,
            llm_keys,
        )
        from app.services.session_db import close_all_pools  # noqa: E402

        _sandbox_modules_loaded = True
    except ImportError:
        logging.getLogger(__name__).warning(
            "SANDBOX flag enabled but sandbox modules not installed — skipping"
        )
```

**Keep** lines 66-67 (`# Conditionally import feature-flagged modules.` and the `# pylint: disable=wrong-import-position,...`) — the four surviving guards still need them. **Keep** `app/services/sidecar_manager.py` and `app/services/session_db.py`: both are live via `app/routers/chat.py:435` and `app/services/sidecars/`.

- [ ] **Step 8: Drop the stale mock line from the existing flag test**

In `rossoctl/backend/tests/test_simulation_flag.py`, delete line 24:

```python
    mock_settings.rossoctl_feature_flag_sandbox = False
```

- [ ] **Step 9: Run the full backend suite**

Run: `cd rossoctl/backend && pytest -q`
Expected: PASS. A failure naming `sandbox`, `close_all_pools` or `_sandbox_modules_loaded` means a reference was missed — grep for it before continuing.

- [ ] **Step 10: Remove the flag from the UI hook**

In `rossoctl/ui-v2/src/hooks/useFeatureFlags.ts`, delete the `sandbox` entry from all three places: the `FeatureFlags` interface (lines 9-10, comment included), `DEFAULT_FLAGS` (line 32), and the `validated` literal (line 58):

```typescript
  /** Sandboxed agent runtime UI and APIs (legacy runtime sandbox). */
  sandbox: boolean;
```
```typescript
  sandbox: false,
```
```typescript
          sandbox: data.sandbox === true,
```

- [ ] **Step 11: Remove the routes and imports from `App.tsx`**

In `rossoctl/ui-v2/src/App.tsx`, delete the five page imports (lines 33-37):

```typescript
import { SandboxPage } from './pages/SandboxPage';
import { SandboxCreatePage } from './pages/SandboxCreatePage';
import { SandboxesPage } from './pages/SandboxesPage';
import { SessionsTablePage } from './pages/SessionsTablePage';
import { SessionGraphPage } from './pages/SessionGraphPage';
```

Delete the route group at 205-213 first (bottom-up), then the one at 157-159:

```jsx
        {features.sandbox && (
          <>
            <Route path="/sandbox" element={<ProtectedRoute><SandboxPage /></ProtectedRoute>} />
            <Route path="/sandbox/create" element={<ProtectedRoute><SandboxCreatePage /></ProtectedRoute>} />
            <Route path="/sandbox/sessions" element={<ProtectedRoute><SessionsTablePage /></ProtectedRoute>} />
            <Route path="/sandbox/graph" element={<ProtectedRoute><SessionGraphPage /></ProtectedRoute>} />
            <Route path="/sandboxes" element={<ProtectedRoute><SandboxesPage /></ProtectedRoute>} />
          </>
        )}
```
```jsx
        {features.sandbox && (
          <>
            <Route path="/sessions" element={<ProtectedRoute><SessionsTablePage /></ProtectedRoute>} />
          </>
        )}
```

Match the surrounding JSX exactly — the fragment wrapper and closing `)}` must go with each block.

- [ ] **Step 12: Remove the nav items from `AppLayout.tsx`**

In `rossoctl/ui-v2/src/components/AppLayout.tsx`, delete the block starting at line **425** first, then the one starting at line **352**. Note these use optional chaining (`features?.sandbox`).

Block at 425 (inside the "Operations" NavGroup):

```jsx
                  {features?.sandbox && (
                    <NavItem
                      itemId="session-graph"
                      isActive={isNavItemActive('/sandbox/graph')}
                      onClick={() => handleNavSelect('/sandbox/graph')}
                    >
                      Session Graph
                    </NavItem>
                  )}
```

Block at 352:

```jsx
                  {features?.sandbox && (
                    <>
                      <NavItem
                        itemId="sandbox"
                        isActive={isNavItemActive('/sandbox')}
                        onClick={() => handleNavSelect('/sandbox')}
                      >
                        Sessions
                      </NavItem>
                      <NavItem
                        itemId="sandboxes"
                        isActive={isNavItemActive('/sandboxes')}
                        onClick={() => handleNavSelect('/sandboxes')}
                      >
                        Sandboxes
                      </NavItem>
                    </>
                  )}
```

- [ ] **Step 13: Fix the barrel that would otherwise break the build**

In `rossoctl/ui-v2/src/pages/index.ts`, delete line 19:

```typescript
export { SandboxCreatePage } from './SandboxCreatePage';
```

`tsconfig.json` sets `"include": ["src"]`, so `tsc` compiles this barrel even though nothing imports it. Leaving the re-export is a hard build failure, not dead weight.

- [ ] **Step 14: Delete the 32 orphaned UI files**

```bash
cd rossoctl/ui-v2
git rm src/pages/SandboxPage.tsx src/pages/SandboxCreatePage.tsx \
  src/pages/SandboxesPage.tsx src/pages/SessionsTablePage.tsx \
  src/pages/SessionGraphPage.tsx \
  src/components/FileBrowser.tsx src/components/FilePreview.tsx \
  src/components/FilePreviewModal.tsx src/components/AgentLoopCard.tsx \
  src/components/DelegationCard.tsx src/components/FloatingViewBar.tsx \
  src/components/GraphDetailPanel.tsx src/components/GraphLoopView.tsx \
  src/components/HitlApprovalCard.tsx src/components/LlmUsagePanel.tsx \
  src/components/LoopDetail.tsx src/components/LoopSummaryBar.tsx \
  src/components/ModelBadge.tsx src/components/ModelSwitcher.tsx \
  src/components/PodStatusPanel.tsx src/components/PromptInspector.tsx \
  src/components/SessionSidebar.tsx src/components/SessionStatsPanel.tsx \
  src/components/SidecarTab.tsx src/components/SimpleLoopCard.tsx \
  src/components/SkillWhisperer.tsx src/components/StepGraphView.tsx \
  src/components/SubSessionsPanel.tsx src/components/TopologyGraphView.tsx \
  src/hooks/useSessionLoader.ts \
  src/utils/historyPairing.ts src/utils/loopFormatting.ts
```

Do **not** touch `SandboxWizard.tsx`, `SandboxConfig.tsx`, `SandboxAgentsPanel.tsx`, `workloadType.ts` or `eventService.ts`.

- [ ] **Step 15: Remove the seven dead `api.ts` units, bottom-up**

In `rossoctl/ui-v2/src/services/api.ts`, delete these exported units in this order (descending line numbers, so earlier deletions don't shift later ones):

| Order | Unit | Lines |
|---|---|---|
| 1 | `getPodEvents` | 1506-1549 |
| 2 | `getPodMetrics` | 1497-1504 |
| 3 | `getPodStatus` | 1462-1495 |
| 4 | `sidecarService` | 1279-1329 |
| 5 | `tokenUsageService` | 1238-1277 |
| 6 | `sandboxFileService` | 1163-1236 |
| 7 | `sessionGraphService` | 802-815 |

**Do not remove `sandboxService` (874-1088) or `modelsService` (1426-1461)** — both are called by the live `SandboxWizard.tsx`. **Do not remove `graphCardService` (1403-1425)** — it is pre-existing dead code, out of scope.

- [ ] **Step 16: Verify no orphaned `api.ts` exports remain for this flag**

`noUnusedLocals` does not flag unused *exports*, so `tsc` cannot catch a leftover. Check by hand:

```bash
cd rossoctl/ui-v2
for s in sessionGraphService sandboxFileService tokenUsageService sidecarService \
         getPodStatus getPodMetrics getPodEvents; do
  echo "$s: $(grep -rn "\b$s\b" src --include='*.ts' --include='*.tsx' | wc -l) refs"
done
```

Expected: `0 refs` for all seven.

- [ ] **Step 17: Run the UI checks**

Run: `cd rossoctl/ui-v2 && npm run typecheck && npm run lint && npm run test:unit && npm run build`
Expected: all PASS. `noUnusedLocals: true` means any missed import fails `typecheck` — that is the machine check on the reachability analysis. If a deleted file is still referenced, the error names it; add it back and re-derive rather than guessing.

- [ ] **Step 18: Remove the chart env var and the LITELLM block**

In `charts/rossoctl/templates/ui.yaml`, delete lines **273-280** first:

```yaml
            {{- if .Values.featureFlags.sandbox }}
            - name: LITELLM_MASTER_KEY
              valueFrom:
                secretKeyRef:
                  name: litellm-proxy-secret
                  key: master-key
                  optional: true
            {{- end }}
```

Then delete lines **154-155**:

```yaml
            - name: ROSSOCTL_FEATURE_FLAG_SANDBOX
              value: "{{ .Values.featureFlags.sandbox }}"
```

- [ ] **Step 19: Narrow the PVC condition — do not delete it**

In `charts/rossoctl/templates/ui.yaml` line **502**, change:

```yaml
  {{- if or .Values.featureFlags.sandbox .Values.featureFlags.simulatedTools }}
```

to:

```yaml
  {{- if .Values.featureFlags.simulatedTools }}
```

Also update the comment two lines below it, which currently credits the sandbox:

```yaml
  # PersistentVolumeClaims — simulated-tool StatefulSet volumes that the delete
  # path enumerates and tears down (#2151).
```

- [ ] **Step 20: Remove the sandbox RBAC rules**

In `charts/rossoctl/templates/ui.yaml`, delete lines **466-480**:

```yaml
  {{- if .Values.featureFlags.sandbox }}
  # Sandbox-specific: create pods, exec, logs, and mutate configmaps/secrets/PVCs
  - apiGroups: [""]
    resources: ["pods"]
    verbs: ["create"]
  - apiGroups: [""]
    resources: ["pods/exec", "pods/log"]
    verbs: ["get", "create"]
  - apiGroups: [""]
    resources: ["configmaps"]
    verbs: ["create", "patch", "delete"]
  - apiGroups: [""]
    resources: ["secrets"]
    verbs: ["create", "patch", "delete"]
  {{- end }}
```

This is the privilege reduction worth naming in the PR: `pods/exec` is container-escape-grade and no shipping code path uses it.

- [ ] **Step 21: Remove the flag from `values.yaml`**

In `charts/rossoctl/values.yaml`, delete lines **10-13**:

```yaml
  # Sandbox runtime (session management, file browser, sidecars).
  # NOT YET FULLY IMPLEMENTED — backend modules not merged. Do not enable.
  # See PR #996
  sandbox: false
```

- [ ] **Step 22: Remove the env var from the openshell deploy script**

In `scripts/openshell/deploy-shared.sh`, delete lines **1011-1012**:

```yaml
        - name: ROSSOCTL_FEATURE_FLAG_SANDBOX
          value: "true"
```

Leave the adjacent `ROSSOCTL_FEATURE_FLAG_ACP` entry alone — `acp.py` exists and that flag works. This script is the reason the bug mattered in practice: it has been enabling a broken UI.

- [ ] **Step 23: Remove the flag from the `CLAUDE.md` flag table**

`CLAUDE.md` has a "Current flags" table under "## Feature Flags (REQUIRED)". Delete line **195**:

```markdown
| `rossoctl_feature_flag_sandbox` | Sandboxed agent runtime UI and APIs |
```

The spec's §7 claim that no documentation changes are needed was derived from `docs/` only and missed this file. `rossoctl_feature_flag_admin` on line 198 stays — that flag is live.

- [ ] **Step 24: Run the chart checks — the Step 1 guards must still pass**

Run: `helm unittest charts/rossoctl && helm lint charts/rossoctl`
Expected: PASS, including both PVC cases from Step 1. If `grants PVC permissions when simulatedTools is enabled` now fails, Step 19 was done as a deletion instead of a narrowing — fix it before committing.

Run: `helm template charts/rossoctl | grep -c ROSSOCTL_FEATURE_FLAG_SANDBOX`
Expected: `0`

- [ ] **Step 25: Commit**

```bash
git add -A
git commit -s -m "fix: remove the unimplemented sandbox feature flag

The sandbox routers were never merged, so the flag's try/except ImportError
swallowed the failure and enabling it produced a navigable UI whose every API
call 404'd. scripts/openshell/deploy-shared.sh set it to true, so this was
shipping broken rather than merely latent.

Removes the flag end to end: backend settings, guard block and route
registrations, the /config/features key, the chart env var, LITELLM secret
mount and RBAC, the openshell env var, the CLAUDE.md flag table row, and 32 UI
files that become unreachable once the routes are gone. The UI set comes from
an import-reachability analysis, not filename matching -- the live agentSandbox
feature owns several Sandbox-named files.

Deleting the RBAC block drops pods/create, pods/exec and pods/log from the
backend ClusterRole, a privilege reduction on a path nothing used.

The PVC rule was gated on `or sandbox simulatedTools` and is narrowed rather
than deleted, so the live simulated-tools delete path (#2151) keeps its
permissions. Pinned by two new helm-unittest cases.

Refs #1764

Assisted-By: Claude (Anthropic AI) <noreply@anthropic.com>"
```

---

### Task 3: Remove the `triggers` flag

**Files:**
- Modify: `rossoctl/backend/tests/test_removed_feature_flags.py`, `app/core/config.py:81`, `app/routers/config.py`, `app/main.py`, `tests/test_simulation_flag.py`
- Modify: `charts/rossoctl/values.yaml`, `charts/rossoctl/templates/ui.yaml`, `CLAUDE.md`
- Modify: `rossoctl/ui-v2/src/hooks/useFeatureFlags.ts`, `src/App.tsx`, `src/components/AppLayout.tsx`, `src/services/api.ts`
- Delete: `rossoctl/ui-v2/src/pages/TriggerManagementPage.tsx`

**Interfaces:**
- Consumes: `REMOVED_FLAGS` from `tests/test_removed_feature_flags.py` (Task 2).
- Produces: `REMOVED_FLAGS` extended with `("triggers", "rossoctl_feature_flag_triggers")`.

- [ ] **Step 1: Extend the failing test**

In `rossoctl/backend/tests/test_removed_feature_flags.py`, extend the tuple:

```python
REMOVED_FLAGS = (
    ("sandbox", "rossoctl_feature_flag_sandbox"),
    ("triggers", "rossoctl_feature_flag_triggers"),
)
```

- [ ] **Step 2: Run it to verify the new cases fail**

Run: `cd rossoctl/backend && pytest tests/test_removed_feature_flags.py -v`
Expected: the two `triggers` cases FAIL; all `sandbox` and live-flag cases PASS.

- [ ] **Step 3: Remove the backend field and response key**

In `rossoctl/backend/app/core/config.py`, delete:

```python
    rossoctl_feature_flag_triggers: bool = False
```

In `rossoctl/backend/app/routers/config.py`, delete from `FeatureFlagsResponse`:

```python
    triggers: bool = Field(description="Event-driven trigger system")
```

and from `get_feature_flags`:

```python
        triggers=settings.rossoctl_feature_flag_triggers,
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd rossoctl/backend && pytest tests/test_removed_feature_flags.py -v`
Expected: all PASS.

- [ ] **Step 5: Remove the guard block and route registration**

In `rossoctl/backend/app/main.py`, delete the registration block first:

```python
if _triggers_modules_loaded:
    app.include_router(sandbox_trigger.router, prefix="/api/v1")
    logger.info("Feature flag TRIGGERS enabled — trigger routes registered")
```

then the guard block:

```python
_triggers_modules_loaded = False
if settings.rossoctl_feature_flag_triggers:
    try:
        from app.routers import sandbox_trigger  # noqa: E402

        _triggers_modules_loaded = True
    except ImportError:
        logging.getLogger(__name__).warning(
            "TRIGGERS flag enabled but trigger modules not installed — skipping"
        )
```

- [ ] **Step 6: Drop the stale mock line**

In `rossoctl/backend/tests/test_simulation_flag.py`, delete:

```python
    mock_settings.rossoctl_feature_flag_triggers = False
```

- [ ] **Step 7: Run the full backend suite**

Run: `cd rossoctl/backend && pytest -q`
Expected: PASS.

- [ ] **Step 8: Remove the flag from the UI hook**

In `rossoctl/ui-v2/src/hooks/useFeatureFlags.ts`, delete all three occurrences:

```typescript
  triggers: boolean;
```
```typescript
  triggers: false,
```
```typescript
          triggers: data.triggers === true,
```

- [ ] **Step 9: Remove the route and import from `App.tsx`**

Delete the import:

```typescript
import { TriggerManagementPage } from './pages/TriggerManagementPage';
```

and the gated route:

```jsx
        {features.triggers && (
          <Route path="/triggers" element={<ProtectedRoute><TriggerManagementPage /></ProtectedRoute>} />
        )}
```

- [ ] **Step 10: Remove the nav item from `AppLayout.tsx`**

Delete the block that started at line 385 in the original file:

```jsx
              {features?.triggers && (
                <NavList>
                  <NavItem
                    itemId="triggers"
                    isActive={isNavItemActive('/triggers')}
                    onClick={() => handleNavSelect('/triggers')}
                  >
                    Triggers
                  </NavItem>
                </NavList>
              )}
```

- [ ] **Step 11: Delete the page and its API client**

```bash
cd rossoctl/ui-v2 && git rm src/pages/TriggerManagementPage.tsx
```

Then delete the `triggerService` export from `src/services/api.ts` (originally lines 1330-1401 — re-locate it by name, since Task 2 shifted the line numbers).

- [ ] **Step 12: Verify no references remain**

Run: `cd rossoctl/ui-v2 && grep -rn '\btriggerService\b\|TriggerManagementPage' src | wc -l`
Expected: `0`

- [ ] **Step 13: Remove the chart env var and values entry**

In `charts/rossoctl/templates/ui.yaml`, delete:

```yaml
            - name: ROSSOCTL_FEATURE_FLAG_TRIGGERS
              value: "{{ .Values.featureFlags.triggers }}"
```

In `charts/rossoctl/values.yaml`, delete:

```yaml
  # Event-driven trigger system.
  # See PR #996
  triggers: false
```

- [ ] **Step 14: Remove the row from the `CLAUDE.md` flag table**

Delete this row from the "Current flags" table:

```markdown
| `rossoctl_feature_flag_triggers` | Event-driven trigger system |
```

- [ ] **Step 15: Run all checks**

Run:
```bash
helm unittest charts/rossoctl && helm lint charts/rossoctl
helm template charts/rossoctl | grep -c ROSSOCTL_FEATURE_FLAG_TRIGGERS   # expect 0
cd rossoctl/backend && pytest -q
cd ../ui-v2 && npm run typecheck && npm run lint && npm run test:unit && npm run build
```
Expected: all PASS, and the grep prints `0`.

- [ ] **Step 16: Commit**

```bash
git add -A
git commit -s -m "fix: remove the unimplemented triggers feature flag

The sandbox_trigger router was never merged, so the flag's swallowed
ImportError left the Triggers page calling an endpoint that 404s.

Removes the flag end to end: backend settings, guard block and route
registration, the /config/features key, the chart env var and values entry, the
CLAUDE.md flag table row, the UI hook flag, route, nav item,
TriggerManagementPage and triggerService.

Refs #1764

Assisted-By: Claude (Anthropic AI) <noreply@anthropic.com>"
```

---

### Task 4: Remove the `integrations` flag

The only slice that deletes a whole chart template: `templates/integration-crd.yaml` is wrapped in `{{- if .Values.featureFlags.integrations }}` at line 1, so the flag's removal empties it entirely.

**Files:**
- Modify: `rossoctl/backend/tests/test_removed_feature_flags.py`, `app/core/config.py:80`, `app/routers/config.py`, `app/main.py`, `tests/test_simulation_flag.py`
- Modify: `charts/rossoctl/values.yaml`, `charts/rossoctl/templates/ui.yaml`, `CLAUDE.md`
- Delete: `charts/rossoctl/templates/integration-crd.yaml`
- Modify: `rossoctl/ui-v2/src/hooks/useFeatureFlags.ts`, `src/App.tsx`, `src/components/AppLayout.tsx`, `src/services/api.ts`
- Delete: 3 UI pages

**Interfaces:**
- Consumes: `REMOVED_FLAGS` from `tests/test_removed_feature_flags.py` (Tasks 2-3).
- Produces: `REMOVED_FLAGS` extended to all three flags. Final state of the file.

- [ ] **Step 1: Extend the failing test**

```python
REMOVED_FLAGS = (
    ("sandbox", "rossoctl_feature_flag_sandbox"),
    ("triggers", "rossoctl_feature_flag_triggers"),
    ("integrations", "rossoctl_feature_flag_integrations"),
)
```

- [ ] **Step 2: Run it to verify the new cases fail**

Run: `cd rossoctl/backend && pytest tests/test_removed_feature_flags.py -v`
Expected: the two `integrations` cases FAIL; everything else PASSes.

- [ ] **Step 3: Remove the backend field and response key**

In `rossoctl/backend/app/core/config.py`, delete:

```python
    rossoctl_feature_flag_integrations: bool = False
```

In `rossoctl/backend/app/routers/config.py`, delete from `FeatureFlagsResponse`:

```python
    integrations: bool = Field(description="Third-party integration endpoints")
```

and from `get_feature_flags`:

```python
        integrations=settings.rossoctl_feature_flag_integrations,
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd rossoctl/backend && pytest tests/test_removed_feature_flags.py -v`
Expected: all PASS.

- [ ] **Step 5: Remove the guard block and route registration**

In `rossoctl/backend/app/main.py`, delete the registration block first:

```python
if _integrations_modules_loaded:
    app.include_router(integrations.router, prefix="/api/v1")
    logger.info("Feature flag INTEGRATIONS enabled — integration routes registered")
```

then the guard block:

```python
_integrations_modules_loaded = False
if settings.rossoctl_feature_flag_integrations:
    try:
        from app.routers import integrations  # noqa: E402

        _integrations_modules_loaded = True
    except ImportError:
        logging.getLogger(__name__).warning(
            "INTEGRATIONS flag enabled but integration modules not installed — skipping"
        )
```

- [ ] **Step 6: Drop the stale mock line, then confirm all three are gone**

In `rossoctl/backend/tests/test_simulation_flag.py`, delete:

```python
    mock_settings.rossoctl_feature_flag_integrations = False
```

Run: `grep -c 'rossoctl_feature_flag_\(sandbox\|triggers\|integrations\)' rossoctl/backend/tests/test_simulation_flag.py`
Expected: `0`

- [ ] **Step 7: Run the full backend suite**

Run: `cd rossoctl/backend && pytest -q`
Expected: PASS. `main.py` should now have exactly four guard blocks left.

Run: `grep -c '_modules_loaded = False' rossoctl/backend/app/main.py`
Expected: `4`

- [ ] **Step 8: Remove the flag from the UI hook**

In `rossoctl/ui-v2/src/hooks/useFeatureFlags.ts`, delete all three occurrences:

```typescript
  integrations: boolean;
```
```typescript
  integrations: false,
```
```typescript
          integrations: data.integrations === true,
```

- [ ] **Step 9: Remove the routes and imports from `App.tsx`**

Delete the three imports:

```typescript
import { IntegrationsPage } from './pages/IntegrationsPage';
import { IntegrationDetailPage } from './pages/IntegrationDetailPage';
import { AddIntegrationPage } from './pages/AddIntegrationPage';
```

and the gated route group:

```jsx
        {features.integrations && (
          <>
            <Route path="/integrations" element={<ProtectedRoute><IntegrationsPage /></ProtectedRoute>} />
            <Route path="/integrations/add" element={<ProtectedRoute><AddIntegrationPage /></ProtectedRoute>} />
            <Route path="/integrations/:namespace/:name" element={<ProtectedRoute><IntegrationDetailPage /></ProtectedRoute>} />
          </>
        )}
```

- [ ] **Step 10: Remove the nav item from `AppLayout.tsx`**

Delete the block that started at line 373 in the original file:

```jsx
              {features?.integrations && (
                <NavList>
                  <NavItem
                    itemId="integrations"
                    isActive={isNavItemActive('/integrations')}
                    onClick={() => handleNavSelect('/integrations')}
                  >
                    Integrations
                  </NavItem>
                </NavList>
              )}
```

- [ ] **Step 11: Delete the three pages and the API client**

```bash
cd rossoctl/ui-v2
git rm src/pages/IntegrationsPage.tsx src/pages/IntegrationDetailPage.tsx \
       src/pages/AddIntegrationPage.tsx
```

Then delete the `integrationService` export from `src/services/api.ts` (originally lines 1089-1162 — re-locate it by name).

- [ ] **Step 12: Verify no references remain**

Run: `cd rossoctl/ui-v2 && grep -rn '\bintegrationService\b\|IntegrationsPage\|IntegrationDetailPage\|AddIntegrationPage' src | wc -l`
Expected: `0`

- [ ] **Step 13: Remove the chart env var, RBAC, values entry and CRD template**

In `charts/rossoctl/templates/ui.yaml`, delete the RBAC block first:

```yaml
  {{- if .Values.featureFlags.integrations }}
  # Integration CRDs for repository integrations
  - apiGroups: ["rossoctl.io"]
    resources: ["integrations", "integrations/status"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  {{- end }}
```

then the env var:

```yaml
            - name: ROSSOCTL_FEATURE_FLAG_INTEGRATIONS
              value: "{{ .Values.featureFlags.integrations }}"
```

In `charts/rossoctl/values.yaml`, delete:

```yaml
  # Third-party integration endpoints.
  # (Currently undocumented)
  integrations: false
```

Delete the whole template — line 1 is `{{- if .Values.featureFlags.integrations }}`, so it renders nothing once the flag is gone:

```bash
git rm charts/rossoctl/templates/integration-crd.yaml
```

- [ ] **Step 14: Remove the last row from the `CLAUDE.md` flag table**

Delete this row from the "Current flags" table:

```markdown
| `rossoctl_feature_flag_integrations` | Third-party integration endpoints |
```

The table should now list only `rossoctl_feature_flag_admin`. Confirm no removed flag survives in the file:

Run: `grep -c 'rossoctl_feature_flag_\(sandbox\|triggers\|integrations\)' CLAUDE.md`
Expected: `0`

- [ ] **Step 15: Run all checks**

Run:
```bash
helm unittest charts/rossoctl && helm lint charts/rossoctl
helm template charts/rossoctl | grep -c ROSSOCTL_FEATURE_FLAG_INTEGRATIONS   # expect 0
cd rossoctl/backend && pytest -q
cd ../ui-v2 && npm run typecheck && npm run lint && npm run test:unit && npm run build
```
Expected: all PASS, and the grep prints `0`.

- [ ] **Step 16: Final repo-wide sweep**

```bash
cd /Users/cwiklik/dev/aiplatform/public/kagenti-fork/kagenti
grep -rn 'featureFlags\.\(sandbox\|triggers\|integrations\)\|FEATURE_FLAG_\(SANDBOX\|TRIGGERS\|INTEGRATIONS\)\|feature_flag_\(sandbox\|triggers\|integrations\)' \
  --exclude-dir=node_modules --exclude-dir=.git --exclude-dir=.claude --exclude-dir=docs .
```

Expected: **zero matches.** The pattern is anchored so it does not match `agentSandbox` / `agent_sandbox`.

`docs/` is excluded on purpose: `docs/_internal/superpowers/plans/2026-04-22-agent-sandbox-workload-type.md` is a historical plan document that references the old flag names, and this spec and plan quote them throughout. None of those are code and none should be rewritten.

**The regex cannot see YAML keys**, so it would not catch a leftover `featureFlags.sandbox: false` in `values.yaml` — check that separately:

```bash
grep -nE '^\s+(sandbox|triggers|integrations):' charts/rossoctl/values.yaml
```

Expected: no output.

Confirm the live flag survived — this is the check that proves the sweep was specific and not a blanket deletion:

```bash
grep -rn 'agentSandbox\|agent_sandbox' charts/rossoctl/values.yaml \
  rossoctl/backend/app/routers/config.py rossoctl/ui-v2/src/hooks/useFeatureFlags.ts
```

Expected: matches in all three files.

- [ ] **Step 17: Commit**

```bash
git add -A
git commit -s -m "fix: remove the unimplemented integrations feature flag

The integrations router was never merged, so the flag's swallowed ImportError
left three Integration pages calling endpoints that 404.

Removes the flag end to end: backend settings, guard block and route
registration, the /config/features key, the chart env var, Integration CRD
RBAC and values entry, templates/integration-crd.yaml (gated entirely on this
flag), the CLAUDE.md flag table row, the UI hook flag, routes, nav item, three
pages and integrationService.

main.py is left with four ImportError guards, all of which guard modules that
are actually present.

Refs #1764

Assisted-By: Claude (Anthropic AI) <noreply@anthropic.com>"
```

---

## Follow-ups (do not fix in this plan)

File these as issues after the PR lands. Both are pre-existing and unrelated to the flags; the spec records them in §7.

1. **The live `agentSandbox` wizard depends on a router that was never merged.** `src/components/SandboxWizard.tsx:43` imports `services/eventService.ts` and calls `eventService.getDefaults()` at `:267`; `eventService` targets the `events` router, one of the eight modules the dead `sandbox` flag imported. `sandboxService.getConfig` and `modelsService.getAvailableModels` are in the same position. A shipping feature calls 404s — which is also why this plan keeps all three untouched.
2. **The sidecar manager has no shutdown hook.** `main.py`'s `get_sidecar_manager().shutdown()` sat behind `if _sandbox_modules_loaded:`, which was never true, while `app/routers/chat.py:435` can instantiate that manager whenever `rossoctl_feature_flag_sidecars` is set. Task 2 removes the dead branch — no behaviour change, since it never ran — but nothing replaces it.
3. **Pre-existing dead UI code**, deliberately out of scope: `EventSubtypeGraphView.tsx`, `SandboxAgentsPanel.tsx`, `SandboxConfig.tsx`, `utils/clipboard.ts`, the three unimported `index.ts` barrels, and `graphCardService` in `api.ts`. All are unreachable today, before any change here.
