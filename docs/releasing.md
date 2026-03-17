# Releasing Kagenti

This guide describes how maintainers create tags, pre-releases, and stable (GA)
releases across the Kagenti organization.

## Versioning Scheme

Kagenti follows [Semantic Versioning 2.0](https://semver.org/) with three
pre-release stages:

```
vX.Y.0-alpha.N   →   vX.Y.0-rc.N   →   vX.Y.0   →   vX.Y.Z (patches)
```

| Tag pattern | Stage | GitHub Release type |
|-------------|-------|---------------------|
| `vX.Y.0-alpha.N` | **Alpha** — active development, may break | Pre-release |
| `vX.Y.0-rc.N` | **Release Candidate** — feature-complete, stabilization only | Pre-release |
| `vX.Y.0` | **General Availability (GA)** — stable, production-ready | Latest |
| `vX.Y.Z` | **Patch** — critical fixes against a GA release | Latest |

GoReleaser's `prerelease: auto` setting automatically marks tags containing
`-alpha` or `-rc` as pre-releases on GitHub. No manual intervention is needed.

## Repositories and Artifacts

The Kagenti platform spans multiple repositories. Each produces different
artifacts when a tag is pushed:

| Repository | Artifacts on tag push | CI workflow(s) |
|------------|----------------------|----------------|
| [kagenti/kagenti](https://github.com/kagenti/kagenti) | Container images (ui-v2, backend, oauth-secrets), Helm charts (kagenti, kagenti-deps) | `build.yaml` |
| [kagenti/kagenti-extensions](https://github.com/kagenti/kagenti-extensions) | Container images (envoy-with-processor, proxy-init, client-registration), webhook binary + ko image, Helm chart (kagenti-webhook-chart) | `build.yaml`, `goreleaser.yml` |
| [kagenti/kagenti-operator](https://github.com/kagenti/kagenti-operator) | Operator image, Helm chart (kagenti-operator-chart) | repo-specific |
| [kagenti/agent-examples](https://github.com/kagenti/agent-examples) | Sample agent/tool images | repo-specific |

## Release Order

The `kagenti/kagenti` Helm chart depends on sub-charts from other repos
(defined in `charts/kagenti/Chart.yaml`). Dependency repos must be tagged
**before** the main repo:

```
1. kagenti/kagenti-operator     →  tag & wait for CI
2. kagenti/kagenti-extensions   →  tag & wait for CI
3. kagenti/agent-examples       →  tag (if applicable)
4. kagenti/kagenti              →  update Chart.yaml, tag
```

## Cutting an Alpha Release

Alpha releases are tagged from `main` during active development.

### Steps (repeat for each repo)

1. Ensure CI passes on `main`.

2. Determine the next alpha number:

   ```bash
   git tag --list 'vX.Y.0-alpha.*' --sort=-v:refname | head -1
   ```

3. Create and push the tag:

   ```bash
   git tag -s vX.Y.0-alpha.N -m "vX.Y.0-alpha.N"
   git push origin vX.Y.0-alpha.N
   ```

4. Verify CI completes:
   - [ ] Container images pushed to `ghcr.io`
   - [ ] GitHub Release created and marked as **Pre-release**
   - [ ] Helm charts published (if applicable)

5. No release notes required — the auto-generated changelog is sufficient.

### Updating kagenti/kagenti after dependency alphas

After tagging `kagenti-extensions` and `kagenti-operator`, update the sub-chart
versions in `charts/kagenti/Chart.yaml`:

```yaml
dependencies:
- name: kagenti-webhook-chart
  version: X.Y.0-alpha.N    # <-- new version
  repository: oci://ghcr.io/kagenti/kagenti-extensions
- name: kagenti-operator-chart
  version: X.Y.0-alpha.N    # <-- new version
  repository: oci://ghcr.io/kagenti/kagenti-operator
```

Run `helm dependency update charts/kagenti/` to regenerate `Chart.lock`, commit,
merge, then tag `kagenti/kagenti`.

## Cutting a Release Candidate

Release candidates signal feature-complete code ready for broader testing.

### Prerequisites

- All planned features for `vX.Y.0` are merged.
- No known critical or blocking bugs.
- Feature freeze declared by maintainers.

### Steps

1. **Tag dependency repos first** with their RC tags (following the
   [release order](#release-order)).

2. **Update `charts/kagenti/Chart.yaml`** in `kagenti/kagenti` to reference
   the new sub-chart RC versions. Run `helm dependency update charts/kagenti/`
   to regenerate `Chart.lock`.

3. **(Optional) Create a release branch** if parallel development on `main` is
   expected:

   ```bash
   git checkout -b release-X.Y main
   git push origin release-X.Y
   ```

   If no parallel work is planned, tag directly from `main`.

4. **Tag the RC:**

   ```bash
   git tag -s vX.Y.0-rc.1 -m "vX.Y.0-rc.1"
   git push origin vX.Y.0-rc.1
   ```

5. **Verify all artifacts:**
   - [ ] Container images pushed with the RC tag
   - [ ] Helm charts pushed to OCI registry
   - [ ] GitHub Release created as **Pre-release**

6. **Test the RC:**
   - [ ] Clean Kind cluster install using the RC tag succeeds
   - [ ] OpenShift install (if applicable) succeeds
   - [ ] E2E tests pass
   - [ ] Upgrade from previous GA version works
   - [ ] Documentation reviewed and updated for new features

7. **If bugs are found:** Fix on the release branch (or `main`), cherry-pick as
   needed, bump to `rc.2`, and repeat from step 4.

## Cutting a GA Release

A GA release is the final, stable, production-ready version.

### Prerequisites

- At least one RC has been validated with no open release-blocking issues.
- Minimum soak period of 1 week since the last RC (recommended).
- At least one maintainer sign-off.

### Steps

1. **Tag dependency repos first** with their GA tags (following the
   [release order](#release-order)).

2. **Update `charts/kagenti/Chart.yaml`** to pin sub-chart versions to their
   GA versions. Run `helm dependency update charts/kagenti/` to regenerate
   `Chart.lock`.

3. **Tag the GA release:**

   ```bash
   git tag -s vX.Y.0 -m "vX.Y.0"
   git push origin vX.Y.0
   ```

4. **Write release notes:**
   - Use GitHub's auto-generated changelog as a starting point.
   - Add a summary section highlighting key features, breaking changes, and
     upgrade notes.
   - List the compatible versions of all Kagenti org repos.

5. **Verify:**
   - [ ] GitHub Release is marked as **Latest** (not Pre-release)
   - [ ] All container images tagged and pushed
   - [ ] Helm charts published to OCI registry
   - [ ] Installation guide version references are up to date

6. **Announce** the release to the community (Discord, mailing list).

## Cutting a Patch Release

Patch releases deliver critical fixes against an existing GA version.

1. Cherry-pick the fix(es) into the `release-X.Y` branch.
2. Tag as `vX.Y.Z` (e.g., `v0.5.1`).
3. Follow the same verification steps as a GA release.
4. For non-trivial fixes, consider cutting a patch RC (`vX.Y.Z-rc.1`) first.

## Troubleshooting

### Stale `Chart.lock`

After updating dependency versions in `Chart.yaml`, always run
`helm dependency update` before committing:

```bash
helm dependency update charts/kagenti/
helm dependency update charts/kagenti-deps/
```

Forgetting this step causes Helm install failures because `Chart.lock` still
references the old versions.

### Pre-release detection

GoReleaser's `prerelease: auto` detects pre-release tags by the presence of a
hyphen after the version (e.g., `-alpha.1`, `-rc.2`). Tags like `v0.5.0` are
treated as stable. No workflow changes are needed to support new pre-release
stages.

### Helm chart version vs. app version

The `version` field in `Chart.yaml` should match the release tag (minus the `v`
prefix). The `appVersion` field may differ if it tracks a different cadence.
