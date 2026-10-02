# Operations

## Terraform backend

State lives in `s3://three-tier-tfstate-123456789012-us-east-1` (versioned, SSE-S3, public access blocked, TLS only, this account only, `prevent_destroy`).

| Root | Key | Manages |
| --- | --- | --- |
| `infra/bootstrap` | `bootstrap/terraform.tfstate` | the state bucket and its protections |
| `infra/stack` | `stack/terraform.tfstate` | everything else |

Locking is native S3 (`use_lockfile = true`): a `.tflock` object next to the state. A second writer waits for `-lock-timeout` and then fails with "Error acquiring the state lock". Never pass `-lock=false`. If a crashed run leaves a lock, confirm nobody is running Terraform, then `terraform force-unlock <ID>` with the ID from the error.

### Working on a root

```bash
cd infra/stack                      # or infra/bootstrap
cp backend.hcl.example backend.hcl  # once; set the bucket name
terraform init -backend-config=backend.hcl
terraform plan -out=/tmp/<name>.tfplan
terraform apply /tmp/<name>.tfplan
```

Keep plan files outside the repository and delete them after use; they can contain sensitive values.

### Bootstrapping a new account

```bash
cd infra/bootstrap
cp local_override.tf.example local_override.tf   # local state until the bucket exists
terraform init && terraform apply
cp backend.hcl.example backend.hcl                # set bucket = $(terraform output -raw state_bucket)
rm local_override.tf
terraform init -migrate-state -backend-config=backend.hcl
terraform plan                                    # expect: No changes
rm terraform.tfstate                              # after confirming the S3 copy
```

### Recovering an earlier state version

Superseded versions are kept for 90 days.

```bash
B=three-tier-tfstate-123456789012-us-east-1; K=stack/terraform.tfstate
aws s3api list-object-versions --bucket $B --prefix $K \
  --query 'Versions[?Key==`'$K'`].[VersionId,LastModified,IsLatest]' --output table
d=$(mktemp -d); chmod 700 $d
aws s3api get-object --bucket $B --key $K --version-id <VersionId> $d/previous.tfstate
```

Inspect it in the temporary directory. To make it live, and only after comparing it with the current state: take a lock by starting `terraform plan` in another shell and cancelling it once you are ready, then run `terraform state push $d/previous.tfstate`; Terraform refuses a push with a lower serial or different lineage unless `-force` is given, which should be avoided. Run `terraform plan` afterwards and delete `$d`.

### Teardown boundary

`terraform destroy` in `infra/stack` removes the deployment only. The bucket and bootstrap state stay. Remove them last, deliberately: empty all object versions, remove `prevent_destroy`, then destroy `infra/bootstrap`.
