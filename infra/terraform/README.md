# Terraform: network and PostgreSQL on AWS

The AWS network and the PostgreSQL database for `tdb-bookings`, for **dev** and **prod**, in `ap-south-1`.
The diagrams and network rules this code implements are in [`docs/architecture`](../../docs/architecture/README.md).

> Nothing here has been applied. CI and local checks use `init -backend=false`, `validate`, `test` (mocked provider),
> `tflint` and `checkov`. `terraform apply` is denied to agents by `.claude/settings.json` and the pre-tool guard.

## Layout

```
infra/terraform/
├── .tflint.hcl              tflint config: terraform "recommended" preset + pinned AWS ruleset
├── bootstrap/               one-time per account: S3 state bucket + KMS key (local state, see below)
├── modules/
│   ├── network/             VPC, 3 subnet tiers per AZ, IGW, NAT per AZ, route tables, sg-app, flow logs
│   └── postgres/            RDS PostgreSQL, sg-db, subnet group, parameter group, KMS key, log groups
├── envs/
│   ├── dev/                 root module: 2 AZs, 1 NAT, single-AZ db.t4g.micro         state key tdb-bookings/dev/…
│   └── prod/                root module: 3 AZs, NAT per AZ, Multi-AZ db.m7g.large     state key tdb-bookings/prod/…
│       └── tests/           plan-time tests (mocked AWS): prod.tftest.hcl, guards.tftest.hcl
└── tests/mocks/             shared mock data for `terraform test` (no credentials, no API calls)
```

Each env is its own root module with its own state, lock and `.terraform.lock.hcl`. A change to dev cannot touch
prod's state, and both envs pin the same provider build.

Environment settings (CIDR, AZs, instance class, Multi-AZ, backups) live in each env's `locals.tf`, not in tfvars:
they are not secret, they are reviewed in the PR like any code, and there is no file to forget to pass. The only input
is `allowed_account_ids`, an optional guard that makes the provider refuse to run against the wrong account.

| Setting | dev | prod |
|---|---|---|
| VPC CIDR | 10.10.0.0/16 | 10.0.0.0/16 |
| AZs | ap-south-1a, 1b | ap-south-1a, 1b, 1c |
| Subnets per AZ (`/24`) | public `.0-1`, app `.10-11`, db `.20-21` | public `.0-2`, app `.10-12`, db `.20-22` |
| NAT gateways | 1 shared | 1 per AZ |
| PostgreSQL | 17, db.t4g.micro, single-AZ, 20→50 GiB gp3 | 17, db.m7g.large, Multi-AZ, 100→500 GiB gp3 |
| Backups / deletion protection | 7 days / off | 30 days / on |

## How to run

Requirements: Terraform **≥ 1.10** (S3 native locking; CI pins 1.11.0), credentials for the target account.

```bash
# 1. Once per account: the state bucket (see "Bootstrapping the state bucket")
terraform -chdir=infra/terraform/bootstrap init
terraform -chdir=infra/terraform/bootstrap apply          # humans only, reviewed

# 2. Each env
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
cd infra/terraform/envs/prod
terraform init -backend-config="bucket=tdb-bookings-tfstate-${ACCOUNT_ID}"
terraform plan -out=tfplan
terraform apply tfplan                                    # humans only, after review
```

Offline checks (what CI runs, no credentials needed):

```bash
cd infra/terraform
terraform fmt -check -recursive -diff
for r in bootstrap envs/dev envs/prod; do
  terraform -chdir=$r init -backend=false -lockfile=readonly && terraform -chdir=$r validate
done
terraform -chdir=envs/dev test && terraform -chdir=envs/prod test
tflint --init --config "$PWD/.tflint.hcl" && tflint --recursive --config "$PWD/.tflint.hcl"
checkov -d . --framework terraform --quiet --compact
```

After changing a provider version, refresh the lock for every platform the team and CI use:
`terraform providers lock -platform=linux_amd64 -platform=darwin_arm64 -platform=darwin_amd64`.

## How Terraform state is stored and shared

**Where.** One S3 bucket per AWS account (`tdb-bookings-tfstate-<account id>`, created by `bootstrap/`), one object
per environment: `tdb-bookings/dev/terraform.tfstate` and `tdb-bookings/prod/terraform.tfstate`. Dev and prod can
live in one account or in separate accounts; each account gets its own bucket either way. The bucket name is passed at
`init` (`-backend-config="bucket=…"`) because it contains the account ID; key, region, encryption and locking are fixed
in each env's `backend.tf`, so everyone uses the same settings.

**Protection of the bucket.**

| Control | Why |
|---|---|
| Versioning on, old versions kept 90 days | A bad apply or a corrupted write can be rolled back by restoring the previous object version. |
| SSE-KMS with a customer-managed key (rotation on), bucket key enabled | State contains resource IDs, endpoints and ARNs. Reading it needs both S3 and KMS permission, and every decrypt is in CloudTrail. |
| Backend `encrypt = true` + `kms_key_id = "alias/tdb-bookings-tfstate"` | Without `kms_key_id`, the S3 backend sends `AES256` explicitly and overrides the bucket default. |
| Bucket policy denies `AES256` uploads | A backend configured without the key fails loudly instead of writing weaker-encrypted state. |
| Bucket policy denies non-TLS requests | State never crosses the network in clear text. |
| Public access block (all four), `BucketOwnerEnforced` | No ACLs, no public policy, ever. |
| `prevent_destroy` on the bucket | `terraform destroy` on bootstrap fails instead of deleting every env's state. |

**Working at the same time (locking).** `use_lockfile = true` (Terraform ≥ 1.10) makes Terraform create
`<key>.tflock` next to the state with a conditional write (`If-None-Match: *`) before any operation that reads or
writes state, and delete it afterwards. S3 accepts only the first writer. No DynamoDB table is needed.

- Two people run `plan` or `apply` on **the same env** at once: the second gets `Error acquiring the state lock` with
  the holder's name, operation and start time. Nothing is written. They can wait with `-lock-timeout=10m`.
- **Different envs** use different keys and lock files, so dev work never blocks prod.
- A saved plan made before someone else's apply is refused at `apply` time ("Saved plan is stale"), because the state
  serial moved. Re-plan.
- A crashed run can leave a stale lock. `terraform force-unlock <LOCK_ID>` is a **human break-glass** step: first
  confirm the holder's process is gone (ask them; check CI). Agents are denied it, like every `terraform state`
  command.

**Recovering a bad state write.** List versions with `aws s3api list-object-versions --bucket <bucket> --prefix
tdb-bookings/prod/`, then copy the last good version over the current one (`aws s3api copy-object … --copy-source
"<bucket>/<key>?versionId=<id>"`), with the env locked against other runs. This is a human-only, reviewed operation.

### Bootstrapping the state bucket

The bucket cannot store its own creation state, so `bootstrap/` uses **local state** (gitignored by `*.tfstate`).
It is applied once per account by a human. Losing that local file is harmless: the bucket has `prevent_destroy` and
can be re-imported. Optionally, after the first apply, add a `backend "s3"` block with key
`bootstrap/terraform.tfstate` and run `terraform init -migrate-state` to move it into the bucket it created.

**If the bootstrap's local state is lost**, nothing is deleted (`prevent_destroy`, 30-day KMS deletion window); the
bucket and key just become unmanaged. Recover by re-importing them into a fresh bootstrap state
(`terraform import aws_s3_bucket.state <bucket>`, `terraform import aws_kms_key.state <key id>`, and the same for the
bucket's sub-resources), a human-only step. After the first apply, the bootstrap state can also be moved into the
bucket it created (`terraform init -migrate-state` with an S3 backend block).

## Production survives the loss of one AZ

| Component | What happens when one of the three AZs fails |
|---|---|
| Subnets | Every tier has a subnet in each of the 3 AZs; the other two keep running. |
| Egress (NAT) | Each AZ's app subnets route `0.0.0.0/0` to the NAT gateway **in the same AZ**. Losing an AZ loses only that AZ's NAT, which only served that AZ's subnets. With a single NAT, losing its AZ would cut egress for all three. |
| PostgreSQL | `multi_az = true`: a synchronous standby in another AZ. If the primary's AZ fails, RDS promotes the standby and moves the endpoint's DNS name to it, typically in **60–120 s**. No committed transaction is lost (synchronous replication). Apps must reconnect (short DNS TTL, connection retry). |
| Workloads (outside this stack) | Pods spread across zones with a PDB (Helm chart, P3); the ALB stops routing to the failed AZ. |

`envs/prod/tests/prod.tftest.hcl` proves the parts this stack owns: 3 AZs, 3 distinct NAT gateways, NAT *i* in public
subnet *i*, app route table *i* → NAT *i*, Multi-AZ on.

Dev deliberately does **not** survive an AZ loss (one NAT, single-AZ DB). That is a cost decision for a disposable
environment and is asserted by `envs/dev/tests/dev.tftest.hcl` so it cannot leak into prod by accident.

## The database is not reachable from the internet

Three independent network layers; any one alone blocks internet access. TLS (4) is on top: it protects the
connection, it is not an access barrier.

1. **No route.** DB subnets use a route table with only the VPC-local route: no internet gateway, no NAT. Nothing in
   them can reach, or be reached from, outside the VPC. They do not share a route table with any other tier.
2. **No public endpoint.** `publicly_accessible = false`: the instance has no public IP and its DNS name resolves to
   a private address.
3. **Security group.** `sg-db` has exactly one ingress rule, TCP 5432 from `sg-app`, and no CIDR rules. It has no
   egress rules at all (Terraform removes AWS's default allow-all egress), so the database cannot open connections out.
4. **TLS required (encryption, not access control).** Parameter group sets `rds.force_ssl = 1` and `ssl_min_protocol_version = TLSv1.2`, so even an
   allowed client must use TLS. Apps should use `sslmode=verify-full` with the RDS CA bundle (`rds-ca-rsa2048-g1`).

The default security group of the VPC is emptied, and the main route table has no routes, so a resource created later
without an explicit SG or subnet association gets no access instead of accidental access.

`sg-app` is created by the network module and output as `app_security_group_id`. The EKS node group / pods for
`tdb-bookings` attach it. It allows egress HTTPS anywhere (via NAT) and 5432 to the DB subnets only.

**Who can reach the database.** Any workload that has the app security group attached (`sg-app`, an output of the env)
can open 5432 to the DB. Only the EKS node group / pod security-group binding for this service should attach it;
treat adding it anywhere else as a change that needs review. Routes and security groups are the controls today; a
DB-tier network ACL is not added (it would duplicate the security-group rule and needs ephemeral-port rules kept in
sync).

**Backups outlive their key only for 30 days.** Destroying an environment keeps the final snapshot and the automated
backups, but also schedules the DB's KMS key for deletion (30-day window). Within that window,
`aws kms cancel-key-deletion --key-id <id>` (human-only) keeps the snapshot restorable; after it, the snapshot is
unusable. Prod has `deletion_protection` on, so this only bites on a deliberate destroy. A key managed outside the
environment's lifecycle would remove the risk and is the follow-up if dev snapshots must be kept.

## How the application gets the database password

No password exists in this repository, in tfvars, or in Terraform state:

1. `manage_master_user_password = true`: RDS generates the master password and stores it in **Secrets Manager**,
   encrypted with the module's KMS key (`master_user_secret_kms_key_id`). Terraform only ever sees the secret's ARN.
   RDS rotates it (every 7 days by default).
2. **External Secrets Operator** in the cluster reads the secret through an IRSA role that has
   `secretsmanager:GetSecretValue` on that one ARN (`db_master_secret_arn` output) and `kms:Decrypt` on
   `db_kms_key_arn`, and writes the Kubernetes Secret `tdb-bookings-db` with `DATABASE_URL`, refreshing it so
   rotations reach the cluster.
3. The Helm chart (P3) only references that Secret by name: `secret.existingSecret: tdb-bookings-db`. Pods read
   `DATABASE_URL` from it at start; a rollout picks up a rotated password.

State caveat: the state still contains non-secret but sensitive data (endpoint, ARNs, IDs). That is why the bucket
is KMS-encrypted and access to it is limited. Never use `password = …` on the instance: Terraform would store it in
state in plain text. A dedicated least-privilege application user (instead of the master user) is the next step; it
is created inside PostgreSQL by a migration, not by Terraform.

## Other production safety settings

`deletion_protection` (prod), final snapshot on delete (`skip_final_snapshot = false`), automated backups kept after
instance deletion, `copy_tags_to_snapshot`, storage encrypted with a CMK, Performance Insights (KMS-encrypted),
Enhanced Monitoring every 60 s, `postgresql` and `upgrade` logs exported to KMS-encrypted log groups with 1-year
retention, slow-query (> 1 s), DDL, connection and lock-wait logging, minor upgrades in the maintenance window
(Mon 01:30–02:30 IST), backups at 00:00–01:00 IST, `apply_immediately = false` so changes wait for the window.
VPC flow logs (all traffic) go to a KMS-encrypted log group through an IAM role scoped to that one log group and
protected against confused-deputy use (`aws:SourceAccount`, `aws:SourceArn`).

## Tests

`terraform test` runs the real env composition against a **mocked AWS provider** (`tests/mocks/aws.tfmock.hcl`):
no credentials, no API calls, nothing created. Runs marked `command = apply` apply to the mock only; that is needed so
generated IDs exist and route → NAT → subnet wiring can be compared.

| File | Proves |
|---|---|
| `envs/prod/tests/prod.tftest.hcl` | Subnet CIDRs match the architecture; 3 AZs, one NAT per AZ in its own AZ's public subnet; each app route table → NAT in its own AZ; no default route in DB subnets; DB route table not shared; Multi-AZ, not public, encrypted, Secrets-Manager password, deletion protection, final snapshot, 30-day backups, `rds.force_ssl = 1`; DB ingress exactly 5432 from `sg-app`, no CIDR. |
| `envs/prod/tests/guards.tftest.hcl` | Input validation rejects: 1 AZ, duplicate AZs, non-/16 VPC, PostgreSQL major other than 16/17, a single DB subnet, no allowed SG, storage ceiling ≤ size. |
| `envs/dev/tests/dev.tftest.hcl` | Dev uses 10.10.0.0/16, 2 AZs, 1 NAT for all app subnets, single-AZ DB, 7-day backups, and the same DB isolation as prod. |

Each assertion was mutation-checked: breaking the code it guards (all app routes to NAT 0, single NAT in prod,
`publicly_accessible = true`, `multi_az = false`, DB subnets on the public route table, `rds.force_ssl = 0`, moved DB
CIDRs, extra subnet in the subnet group) turns the suite red.

## Security scan exceptions

`checkov` runs without `--soft-fail`; any failed check fails CI. Each exception is an inline
`#checkov:skip=<id>:<reason>` next to the resource:

| Check | Where | Reason |
|---|---|---|
| CKV_AWS_109, CKV_AWS_111, CKV_AWS_356 | the three KMS key policies | In a key policy `Resource "*"` means "this key"; admin stays with the account root so IAM policies govern use. The logs service grant is pinned by encryption context to specific log groups. |
| CKV_AWS_144 | state bucket | No cross-region replication: versioning + KMS deletion window cover the realistic loss cases for a single-region service. |
| CKV_AWS_18 | state bucket | No server access logs. Audit of state reads/writes must come from **CloudTrail S3 data events for this bucket**, which this code does not create: it assumes the account/organization trail covers them (CloudTrail does not log S3 object access by default). Check that before relying on it. |
| CKV2_AWS_62 | state bucket | No consumer for S3 event notifications. |
| CKV2_AWS_5 | `sg-app` | Attached by the EKS node group / pods, which are outside this stack. |
| CKV_AWS_157 | `aws_db_instance` | `multi_az` is an input: true in prod (asserted by tests), false in dev for cost. |
| CKV_AWS_293 | `aws_db_instance` | `deletion_protection` is an input: true in prod (asserted by tests), false in dev so it can be torn down. |

## Cost notes (dev)

Approximate on-demand prices in ap-south-1; check the AWS Pricing Calculator before relying on them.

| Item | Approx. per month | Lever |
|---|---|---|
| 1 NAT gateway (+ data processed) | ~US$ 40 + ~US$ 0.05/GB | Biggest fixed dev cost. Prod pays this ×3 for AZ independence. |
| db.t4g.micro single-AZ + 20 GiB gp3 | ~US$ 15–20 | Multi-AZ would double it. |
| 2 KMS keys (flow logs, DB) + 1 for state | ~US$ 3 | |
| Flow logs + RDS logs in CloudWatch | usage-based | Both modules take a retention input (`flow_log_retention_days`, `log_retention_days`); default 365 days. |

Further dev savings that were not taken, to keep dev structurally identical to prod: VPC endpoints instead of NAT for
AWS APIs, or stopping the DB out of hours (RDS restarts stopped instances after 7 days).

## Out of scope (and why)

- **EKS cluster, node groups, ALB, AWS Load Balancer Controller, External Secrets Operator.** These are the platform
  the Helm chart (P3) deploys onto, usually owned by a platform team and shared by many services. This stack provides
  what they need from it: app subnets tagged `kubernetes.io/role/internal-elb`, public subnets tagged
  `kubernetes.io/role/elb`, `sg-app`, and the secret / KMS ARNs as outputs.
- **`terraform plan` in CI.** It needs AWS credentials. The next step is a GitHub OIDC role with read-only rights for
  `plan` on PRs and a separate, environment-protected role for `apply` from `main`; no long-lived keys.
- **Application database user and schema.** Created inside PostgreSQL by migrations, not by Terraform.
- **Cross-region disaster recovery** (snapshot copy / read replica in another region). The requirement is AZ loss;
  region loss is a separate decision with its own cost.
