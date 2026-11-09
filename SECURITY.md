# Security policy

## Reporting a vulnerability

Please use GitHub's **private vulnerability reporting** (Security tab → "Report a vulnerability").
Do not open a public issue for a security problem.

## What protects this repository

| Layer | Control |
|---|---|
| Secrets | No secret values in git. `gitleaks` in pre-commit and CI; GitHub secret scanning with push protection. |
| Dependencies | Locked (`uv.lock`), `pip-audit` in CI, Dependabot alerts and update PRs. |
| Container | Non-root, minimal base pinned by digest, Trivy scan; a CRITICAL finding blocks publishing. |
| Infrastructure code | `checkov` and `tflint` on every PR. `terraform apply` is never run from this repo's automation. |
| CI | Least-privilege `GITHUB_TOKEN`, actions pinned by commit SHA, no `pull_request_target`. |
| `main` | Changes only through PRs, CI must pass, review threads must be resolved, no force-push or deletion. |
| AI agents | Permission rules + a tested pre-tool guard (`.claude/hooks/guard.py`) that also covers shell writes; agents cannot change their own controls, and CI/pre-commit/Dependabot edits need a human's approval. See `AGENTS.md` → Agent safety. |
