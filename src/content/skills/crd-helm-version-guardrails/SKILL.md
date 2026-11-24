---
name: crd-helm-version-guardrails
description: >
  Note: this skill file is not yet optimised for context efficiency, env
  reliability, or CI speed. It is a work in progress.

  Executable checklist for Helm operator chart bumps that ship CRDs — crdify,
  Pluto, kubeconform, fixture updates, and multi-hop compares before merge.
---

Companion narrative:
[Spot Breaking CRD Changes Before Your Helm Chart Bump Hits the Cluster](/blogs/spotting-crd-breaking-changes-helm/).

Argo CD ApplicationSet reviews should chain here from
[argocd-helm-master-repo-guardrails](/skills/argocd-appset/SKILL.md) whenever
`targetRevision` moves an operator that installs CRDs.

## Artefacts in this repo

| Purpose                         | Published URL                                                                                               |
| ------------------------------- | ----------------------------------------------------------------------------------------------------------- |
| ESO fixture set                 | `/manifests/eso/` (`externalsecret.yaml`, `secretstore.yaml`, `clustersecretstore.yaml`, `pushsecret.yaml`) |
| CI driver script                | `/blog-scripts/crd-compat.sh`                                                                               |
| Example GitHub Actions workflow | `/workflow/crd-compat.yml`                                                                                  |

## When this skill applies

- Helm chart version pin changes for operators that bundle CRDs under `crds/`.
- Renovate / Dependabot PRs touching `Chart.yaml`, `Chart.lock`, or operator values pins.
- Argo CD Application or ApplicationSet diffs that only show Deployments but not CRD deltas.

## Gates (run on every minor hop, not only the final pin)

1. **Extract** old and new chart tarballs; compare each paired CRD with **crdify**.
2. **Pluto** on fixture manifests → fail on REMOVED apiVersions; policy for DEPRECATED.
3. **kubeconform** fixtures against OpenAPI from the _target_ chart CRDs (automatically converted into JSON schemas in `schemas/` via `openapi2jsonschema.py`).
4. Record `crdImpact` in the PR; block merge on hard failures.

## Field / policy expectations

| Version / change type                                        | Default CI policy           | Human requirement                |
| ------------------------------------------------------------ | --------------------------- | -------------------------------- |
| Patch, optional fields only                                  | crdify + kubeconform        | Short PR note                    |
| Minor with new optional fields                               | same                        | Confirm no new `required`        |
| Minor/major with new `required`, removals, type/enum tighten | fail until fixtures updated | Migration notes + owner sign-off |
| Served apiVersion removal                                    | fail until Pluto clean      | Dual-serve bridge + inventory    |

## ESO worked example

One pin delta per invocation (repeat per minor hop; do not jump `0.15.x` → `0.17.0` in one crdify pass):

```bash
OLD_VER=0.15.2 NEW_VER=0.16.1 src/content/scripts/crd-compat.sh
OLD_VER=0.16.2 NEW_VER=0.17.0 src/content/scripts/crd-compat.sh
```

From repo root after clone; cloned CRDs land in `src/content/.crd-compat/work/`; fixtures live in `src/content/manifests/eso/`. Add `--run-pluto` or `--run-kubeconform` (or `--all-gates`) to validate fixtures.

## Do not

- Rely on `helm upgrade` or Argo CD sync alone to upgrade in-cluster CRDs.
- Trust Deployment-only diffs or changelog-only review for CRD landmines.
- Skip the `0.15.x` → `0.16.x` hop when landing on `v0.17.0`.
