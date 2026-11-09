# 0004: Terraform state and layout

- Status: accepted
- Date: 2026-11-09
- Problem: P4 (AWS network and PostgreSQL for dev and prod)

## Context

Several engineers (and CI) change the same AWS infrastructure. State must not be lost, read by the wrong people, or
written by two runs at once, and a change to dev must not be able to damage prod.

## Decision

1. **One root module per environment** (`infra/terraform/envs/{dev,prod}`) composing shared modules
   (`modules/network`, `modules/postgres`). Not Terraform workspaces: separate roots make the env visible in the path,
   in the PR diff and in the state key, and each can pin its own settings in `locals.tf`.
2. **S3 backend, one bucket per account, one key per env** (`tdb-bookings/<env>/terraform.tfstate`). Bucket created
   once by `bootstrap/` (local state): versioned, SSE-KMS with a rotated CMK, TLS-only, public access blocked,
   `BucketOwnerEnforced`, AES256 uploads denied so the backend must use the CMK.
3. **S3 native locking** (`use_lockfile = true`, Terraform ≥ 1.10) instead of a DynamoDB lock table: one fewer
   resource to create, pay for and secure, and the lock lives next to the state it protects.
4. **Non-secret env settings in code** (`locals.tf`), not tfvars. No secret ever reaches Terraform: RDS generates the
   master password into Secrets Manager (`manage_master_user_password`).
5. **Provider pinned** `~> 6.0` with `.terraform.lock.hcl` committed for linux_amd64, darwin_arm64 and darwin_amd64;
   CI initialises with `-lockfile=readonly`.

## Consequences

- Two concurrent runs on one env: the second fails fast with the lock holder's details. Different envs never block
  each other.
- A stale lock needs `terraform force-unlock`, a human-only break-glass step.
- The bucket name contains the account ID, so it is passed at `init` with `-backend-config`.
- Bootstrap state is local; losing it is harmless (`prevent_destroy`, re-import), or it can be migrated into the bucket.
- Requires Terraform ≥ 1.10 for everyone; enforced by `required_version`.
