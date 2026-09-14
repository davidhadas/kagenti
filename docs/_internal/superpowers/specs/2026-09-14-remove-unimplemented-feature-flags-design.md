# Remove the unimplemented `sandbox`, `triggers` and `integrations` feature flags

**Issue:** [#1764](https://github.com/rossoctl/rossoctl/issues/1764)
**Date:** 2026-09-14
**Status:** design approved, awaiting implementation plan

## 1. Problem

Three feature flags gate UI that has no backend. Their routers were never
merged, so enabling a flag produces a navigable UI whose every API call
returns 404.

| Flag | Backend modules it imports | Present in `app/routers/`? |
|---|---|---|
| `sandbox` | `sandbox`, `sandbox_deploy`, `sandbox_files`, `token_usage`, `sidecar`, `events`, `models`, `llm_keys` | none |
| `triggers` | `sandbox_trigger` | no |
| `integrations` | `integrations` | no |

The failure is silent by construction. Each import sits in a
`try/except ImportError` that logs a warning and continues:

```python
    except ImportError:
        logging.getLogger(__name__).warning(
            "SANDBOX flag enabled but sandbox modules not installed — skipping"
        )
```

`_sandbox_modules_loaded` stays `False`, `app.include_router(...)` is skipped,
and `/api/v1/config/features` still reports `sandbox: true` — so the UI renders
routes and nav items for an API that is not mounted.

**This is not hypothetical.** `scripts/openshell/deploy-shared.sh:1011` sets
`ROSSOCTL_FEATURE_FLAG_SANDBOX=true`. That deployment has been getting a broken
Sessions/Sandboxes UI, silently, for as long as the script has existed.

All three flags default to `false` and two carry explicit warnings in
`values.yaml` ("NOT YET FULLY IMPLEMENTED — backend modules not merged. Do not
enable."). Nothing depends on them working.

## 2. Decision

**Delete all three flags and every artifact that exists only to serve them.**

The alternative — finishing the backends — is not on the table: the routers live
in an unmerged PR (#996) of unknown currency, and the UI has drifted for
months. Carrying a flag that must not be enabled is worse than carrying nothing,
because it presents as a supported option in `values.yaml`.

### 2.1 Guard blocks: three go, four stay and get hardened

`main.py` has **seven** `try/except ImportError` guard blocks. Only three guard
missing modules. The other four guard modules that are present
(`skills.py`, `acp.py`, `simulation.py`, `dream.py`) and must be kept:

| Flag | Module | Present | Action |
|---|---|---|---|
| `sandbox` | 8 routers + `close_all_pools` | no | delete block |
| `triggers` | `sandbox_trigger` | no | delete block |
| `integrations` | `integrations` | no | delete block |
| `skills` | `skills.py` | yes | keep, harden |
| `acp` | `acp.py` | yes | keep, harden |
| `simulated_tools` | `simulation.py` | yes | keep, harden |
| `dreaming` | `dream.py` | yes | keep, harden |

Hardening means adding `exc_info=True` to the four surviving handlers. Today a
real `ImportError` inside one of those modules — a genuine bug, not a missing
file — is reported as "modules not installed" with the traceback discarded. That
is the same information loss that let this issue reach production, and it costs
one keyword to close.

## 3. Commit sequence

Four commits. The first is a no-op safety improvement; the next three are
vertical slices, one per flag, each spanning backend + chart + UI + scripts so
that no commit leaves a flag half-removed.

1. `fix(backend): log ImportError tracebacks on flagged router guards`
2. `fix: remove the unimplemented sandbox feature flag`
3. `fix: remove the unimplemented triggers feature flag`
4. `fix: remove the unimplemented integrations feature flag`

Every commit must build, `helm template`, and pass tests on its own. Section 6
establishes that the three UI deletion sets are disjoint, which is what makes
this ordering safe.

## 4. Change surface

### 4.1 Backend (`rossoctl/backend/`)

| File | Change |
|---|---|
| `app/core/config.py:79-81` | delete the three `rossoctl_feature_flag_*` Settings fields |
| `app/main.py:68-88` | delete the `sandbox` guard block (incl. the `close_all_pools` import) |
| `app/main.py:89-99` | delete the `triggers` guard block |
| `app/main.py:100-109` | delete the `integrations` guard block |
| `app/main.py:227-233` | delete the `if _sandbox_modules_loaded:` shutdown branch |
| `app/main.py:274-291` | delete the three `if _*_modules_loaded:` `include_router` branches |
| `app/routers/config.py:32-34` | delete the three fields from `FeatureFlagsResponse` |
| `app/routers/config.py:89-91` | delete the three kwargs from `get_feature_flags` |
| `tests/test_simulation_flag.py:24-26` | delete the three now-meaningless mock assignments |

Two `pylint: disable` comments become unnecessary once the dead branches are
gone and should be re-evaluated rather than preserved by reflex:
`main.py:272-273`'s `used-before-assignment` disable is still needed by the four
surviving flags, but the `# pylint: disable=used-before-assignment` on the
`close_all_pools` call at `:233` disappears with its call site.

**`app/services/session_db.py` and `app/services/sidecar_manager.py` stay.**
Both are live: `sidecar_manager` is imported by `app/routers/chat.py:435` and by
the three sidecar implementations under `app/services/sidecars/`, and it imports
`session_db` itself. Only `main.py`'s references to them go.

### 4.2 Chart (`charts/rossoctl/`)

| File | Change |
|---|---|
| `values.yaml:10-19` | delete the three flag entries and their warning comments |
| `templates/ui.yaml:154-159` | delete the three `ROSSOCTL_FEATURE_FLAG_*` env vars |
| `templates/ui.yaml:273-280` | delete the `sandbox`-gated `LITELLM_MASTER_KEY` block |
| `templates/ui.yaml:466-480` | delete the `sandbox` RBAC rules |
| `templates/ui.yaml:502` | **narrow, do not delete** — see §5 |
| `templates/ui.yaml:521-526` | delete the `integrations` (Integration CRD) RBAC rules |
| `templates/integration-crd.yaml` | delete the whole file — line 1 wraps it in `{{- if .Values.featureFlags.integrations }}` |

### 4.3 Scripts

`scripts/openshell/deploy-shared.sh:1011-1012` — delete the
`ROSSOCTL_FEATURE_FLAG_SANDBOX: "true"` env entry. The adjacent
`ROSSOCTL_FEATURE_FLAG_ACP: "true"` is legitimate (`acp.py` exists) and stays.

### 4.4 UI (`rossoctl/ui-v2/src/`)

| File | Change |
|---|---|
| `hooks/useFeatureFlags.ts:9-12, 32-34, 58-60` | delete the three flags from `FeatureFlags`, `DEFAULT_FLAGS`, and the `validated` literal |
| `App.tsx:27-29, 33-38` | delete the nine dead page imports |
| `App.tsx:150-154, 157-159, 162-163, 205-213` | delete the four flag-gated `<Route>` groups (13 routes) |
| `components/AppLayout.tsx` at `352`, `373`, `385`, `425` | delete the four `features?.sandbox` / `?.integrations` / `?.triggers` nav blocks (5 nav items) |
| `services/api.ts` | delete the client functions reachable only from deleted pages — see §4.5 |
| 36 files | delete outright — enumerated in §6 |

`AppLayout.tsx` uses optional chaining (`features?.sandbox`), which is why a
grep for `features.sandbox` does not find it. It is live and must be **edited**,
not deleted.

### 4.5 `services/api.ts`: method, not a list

`api.ts` is 1,783 lines of live shared client code. Thirteen call sites target
dead endpoints (`/sandbox/...`, `/integrations`, `/sandbox/trigger`, `/models`),
but the exported functions wrapping them must be removed by **caller analysis,
not path matching** — some may be called from surviving code.

The procedure, per commit: for each exported symbol whose body targets a dead
endpoint, grep the whole `src/` tree for remaining callers after that commit's
page deletions. Remove only those with zero. `tsc` will not catch a leftover —
`noUnusedLocals` does not flag unused *exports* — so this grep pass is the check
and must be run explicitly rather than assumed.

**`services/eventService.ts` stays entirely untouched.** See §7.

## 5. The one edit that is not a deletion

`templates/ui.yaml:502` reads:

```yaml
  {{- if or .Values.featureFlags.sandbox .Values.featureFlags.simulatedTools }}
```

It gates PersistentVolumeClaim RBAC shared with **`simulatedTools`**, a live
feature (epic #2151). It must be narrowed:

```yaml
  {{- if .Values.featureFlags.simulatedTools }}
```

Deleting the block along with the rest of the `sandbox` RBAC would silently
strip PVC create/delete permissions from the live simulated-tools path. This is
the single highest-risk line in the change, and §8 pins it with a dedicated
`helm template` assertion.

## 6. UI deletion set: 36 files, computed

The deletion set was derived mechanically, not by filename. Rationale: the live
`agentSandbox` feature owns files named `SandboxWizard.tsx`,
`SandboxConfig.tsx`, `SandboxAgentsPanel.tsx` and `workloadType.ts`, so any
name-matching sweep would break working code.

**Method.** Build an import graph over all 104 `.ts`/`.tsx` files under `src/`,
resolving the `@/*` alias (per `tsconfig.json`), relative specifiers, and
`index.*` directory resolution. Compute reachability from `src/main.tsx`,
`src/App.tsx` and all test files. Take the difference between reachability
before and after removing each flag's routes, cumulatively in commit order.

**Result — the three sets are disjoint.** No component is shared between flags,
so each commit's deletion cannot break a later commit's build:

**Commit 2, `sandbox` — 32 files**

```
pages/SandboxPage.tsx            pages/SandboxCreatePage.tsx
pages/SandboxesPage.tsx          pages/SessionsTablePage.tsx
pages/SessionGraphPage.tsx
components/FileBrowser.tsx       components/FilePreview.tsx
components/FilePreviewModal.tsx  components/AgentLoopCard.tsx
components/DelegationCard.tsx    components/FloatingViewBar.tsx
components/GraphDetailPanel.tsx  components/GraphLoopView.tsx
components/HitlApprovalCard.tsx  components/LlmUsagePanel.tsx
components/LoopDetail.tsx        components/LoopSummaryBar.tsx
components/ModelBadge.tsx        components/ModelSwitcher.tsx
components/PodStatusPanel.tsx    components/PromptInspector.tsx
components/SessionSidebar.tsx    components/SessionStatsPanel.tsx
components/SidecarTab.tsx        components/SimpleLoopCard.tsx
components/SkillWhisperer.tsx    components/StepGraphView.tsx
components/SubSessionsPanel.tsx  components/TopologyGraphView.tsx
hooks/useSessionLoader.ts
utils/historyPairing.ts          utils/loopFormatting.ts
```

**Commit 3, `triggers` — 1 file**

```
pages/TriggerManagementPage.tsx
```

**Commit 4, `integrations` — 3 files**

```
pages/IntegrationsPage.tsx  pages/IntegrationDetailPage.tsx
pages/AddIntegrationPage.tsx
```

`SkillWhisperer.tsx` warrants a reviewer's eye: it lands in the `sandbox` set
because only sandbox pages import it, despite the name's proximity to the live
`skills` flag. The graph is correct — it has no other importer — but the name
invites a double-take, so call it out in the PR body.

## 7. Explicitly out of scope

**Seven files are already unreachable today**, before any change here. They are
pre-existing dead code, unrelated to these flags, and are left alone:

```
components/EventSubtypeGraphView.tsx  components/SandboxAgentsPanel.tsx
components/SandboxConfig.tsx          utils/clipboard.ts
hooks/index.ts  pages/index.ts  services/index.ts
```

The three `index.ts` barrels are unreachable because nothing imports them at
all — not because their exports are dead. Consequently **no barrel file needs
editing** in this change.

**Two pre-existing defects were discovered and are deliberately not fixed
here.** Both should be filed as follow-ups; neither is caused or worsened by
this change:

1. **The live `agentSandbox` wizard calls a route that was never merged.**
   `components/SandboxWizard.tsx:43` imports `services/eventService.ts` and
   calls `eventService.getDefaults()` at `:267`. `eventService` targets the
   `events` router — one of the eight modules the dead `sandbox` flag was
   importing. So a live, shipping feature depends on a 404. `eventService.ts` is
   therefore **not** deleted and **not** trimmed: `AuthContext.tsx:16` also
   imports from it.

2. **The sidecar manager is never shut down.** `main.py:228-230` calls
   `get_sidecar_manager().shutdown()` inside `if _sandbox_modules_loaded:`,
   which is never true. Meanwhile `chat.py:435` can instantiate that manager
   whenever `rossoctl_feature_flag_sidecars` is set. Removing the dead branch
   changes no runtime behaviour — it never ran — but it does remove the only
   shutdown hook that was ever written for it.

**No documentation and no UI tests change.** Neither references any of the three
flags: the five UI test files under `src/` touch none of the deleted code, and
`docs/reference/install-options.md` and `docs/operate/install-helm.md` do not
list these flags.

## 8. Verification

Per commit:

- `helm template charts/rossoctl` at defaults — must render, and must contain no
  `ROSSOCTL_FEATURE_FLAG_{SANDBOX,TRIGGERS,INTEGRATIONS}`.
- `helm template charts/rossoctl --set featureFlags.simulatedTools=true` — must
  still contain the `persistentvolumeclaims` RBAC rule. This is the §5
  regression guard and is the one assertion that must not be skipped.
- `helm lint charts/rossoctl`.
- `cd rossoctl/backend && pytest` — full suite, not just
  `test_simulation_flag.py`.
- `cd rossoctl/ui-v2 && npm run build` — `tsconfig.json` sets
  `noUnusedLocals: true` and `noUnusedParameters: true`, so an orphaned import
  fails the build. This is what machine-checks §6's reachability analysis.
- The §4.5 grep pass for orphaned `api.ts` exports, which `tsc` cannot catch.

Final sweep across the whole repo:

```
grep -rn 'featureFlags\.\(sandbox\|triggers\|integrations\)\|FEATURE_FLAG_\(SANDBOX\|TRIGGERS\|INTEGRATIONS\)\|feature_flag_\(sandbox\|triggers\|integrations\)'
```

Expected: zero matches. The pattern is anchored on word boundaries so it does
not match `agentSandbox` / `agent_sandbox`; verify that by confirming the live
`agentSandbox` references still exist afterwards.

## 9. Consequences

**A privilege reduction, not just a cleanup.** Deleting the `sandbox` RBAC
block permanently removes `pods` `create`, `pods/exec` `get`+`create`, and
`pods/log` from the backend ClusterRole, along with `configmaps` and `secrets`
`create`/`patch`/`delete`. `pods/exec` in particular is a container-escape-grade
permission that no shipping code path uses. Worth leading with in the PR body.

**A stale `featureFlags.sandbox: true` becomes a silent no-op rather than a
Helm error.** The chart has no `values.schema.json`, so Helm ignores unknown
keys. For a flag that has never worked and defaults to `false`, degrading from
"silently broken UI" to "silently ignored key" is a strict improvement, and
adding a schema to produce a hard failure is out of scope. Accepted.

**`/api/v1/config/features` drops three keys.** This is a
breaking-shaped-but-not-breaking change: `useFeatureFlags.ts` reads keys
defensively (`data.sandbox === true`) and is updated in the same commit, and no
external consumer of that endpoint exists in this repo.
