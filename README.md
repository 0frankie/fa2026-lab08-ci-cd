# Lab 09: CI/CD with GitHub Actions

In Lab 06 you deployed a website with Terraform, and in Lab 07 a function with Pulumi. Both times the thing that actually ran the deploy was _you_, typing `apply` and then `yes`. The infrastructure was code; the deployment was still a person.

That doesn't scale. State lives on one laptop, nobody reviews a plan that scrolls past in your terminal, and the only record of what shipped is your shell history.

**CI/CD** moves the deploy into the repo: a pull request produces a `terraform plan` a reviewer can read, and a merge to `main` produces a `terraform apply` nobody has to remember to run. In this lab you'll grow the Lab 06 S3 website into a multi-file site published by Terraform, move its state somewhere a CI runner can reach, and write the **GitHub Actions** workflow that deploys it on every merge.

Like Labs 06 and 07, this runs against a **real AWS account**. The resources are effectively free at this scale, but they are real: follow the cleanup steps, and never commit your AWS credentials.

## Setup

- **[Terraform CLI](https://developer.hashicorp.com/terraform/install)** — `brew install terraform`. Needs **1.11 or newer** (where the S3 backend's built-in state locking went GA); check with `terraform version`.
- **[AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html)** — `brew install awscli`.
- **[GitHub CLI](https://cli.github.com/)** (optional but handy) — `brew install gh`, then `gh auth login`. Everything below also works in the web UI.
- A GitHub account and **a repository you own** (see below).

### AWS credentials

Same credentials as Labs 06 and 07 — check your inbox. Configure them under a named profile:

```bash
aws configure --profile cis1912
```

Enter your Access Key ID, Secret Access Key, `us-east-1`, and `json`.

Unlike Lab 06, `main.tf` here does **not** name a profile. Point your shell at it instead, once per terminal session:

```bash
export AWS_PROFILE=cis1912
aws sts get-caller-identity
```

You should see your account ID and IAM user ARN.

A named profile is a file on your laptop, and the Actions runner has no `~/.aws/credentials` — so pinning `profile = "cis1912"` in `main.tf` would work for you and fail in CI. With no profile pinned, the AWS provider falls back to the standard `AWS_*` environment variables: you supply them with `export AWS_PROFILE`, CI supplies them from repository secrets. One config, two environments.

### Your own repository

Actions runs workflows out of the repo they're committed to, and only an admin can add the secrets this lab needs — so it has to live in **your** repo, not the course one.

```bash
gh repo create lab-09-ci-cd --private --source=. --remote=origin --push
```

Or create an empty private repo on github.com and follow its "push an existing repository" instructions. Either way, confirm:

```bash
git remote -v
gh repo view --web
```

## Part A: Publish the site from your laptop

Automating a deploy you can't do by hand means automating something you don't understand yet.

- `site/` — the website: `index.html` and `style.css`, plain files in the repo rather than HTML buried inside a `.tf`.
- `terraform/main.tf` — Lab 06's bucket, website configuration, public access block, and bucket policy, plus one new resource that publishes `site/`.
- `terraform/variables.tf`, `terraform/terraform.tfvars` — the bucket name, pulled out into config.
- `terraform/backend.tf` — where state lives; ignore until Part B.
- `.github/workflows/deploy.yml` — the pipeline; ignore until Part D.

**1. Name your bucket.** In `terraform/terraform.tfvars`, fill in the `<FILL_IN>`. S3 bucket names are global across AWS, so use something like `lab09-<your-pennkey>-website`.

**2. Publish the site directory.** In `terraform/main.tf`, find `aws_s3_object.site`. Lab 06 uploaded one object with its HTML written inline; this one uses `for_each` to manage one object per file in `site/`. Two blanks:

- `for_each` — every file under `local.site_dir`, at any depth. (Hint: `fileset()`, with `"**"` as the pattern.)
- `etag` — a hash of each file's contents, so that _changing_ a file registers as a change to apply. (Hint: `filemd5()`.)

Read the comments above both; the `etag` one is a bug you will eventually hit in a real pipeline.

**3. Deploy.** Local state is fine for now:

```bash
cd terraform
terraform init
terraform plan
```

The plan should show the bucket, its three configuration resources, and **one `aws_s3_object.site[...]` per file in `site/`**. One object, or none, means revisiting `for_each`.

```bash
terraform apply
curl $(terraform output -raw website_url)
```

Open the URL in a browser too — a styled page means `style.css` went up with the right `content_type`.

**4. Watch `etag` do its job.** Edit `site/index.html` (`../site/index.html` from where your shell is), changing the `build: unknown` line to say something else, then `terraform plan`.

Terraform should report **one object to update, in place** — a diff that exists only because of `etag`. Without it, state knows only that an object named `index.html` exists, which is still true, so Terraform reports "no changes" and your edit never ships. Apply and curl again to confirm.

> To see that failure yourself: comment out `etag`, apply, edit the HTML, plan again. A green pipeline deploying nothing is a genuinely nasty bug. Put `etag` back afterward.

**Don't destroy anything yet** — Part B moves this deployment's state, and Part D hands it to CI.

## Part B: Move the state off your laptop

Still in `terraform/` from Part A:

```bash
ls terraform.tfstate
```

That file is the only record of what Terraform created. A runner starts from a fresh `git clone` on an empty disk, and `.gitignore` (correctly) keeps state out of git — so it would see no state at all, decide your bucket doesn't exist, try to create it, and fail with `BucketAlreadyOwnedByYou`.

The fix is a **remote backend**: state in S3, where you and every CI run read and write the same copy.

**1. Create the state bucket by hand.** Terraform can't create the bucket that holds its own state — it would have to read that state to know whether the bucket exists. This chicken-and-egg bootstrap is normal, and one-time:

```bash
export STATE_BUCKET=lab09-<your-pennkey>-tfstate
aws s3api create-bucket --bucket $STATE_BUCKET --region us-east-1
```

Turn on versioning, so a bad write doesn't leave you with no way back:

```bash
aws s3api put-bucket-versioning --bucket $STATE_BUCKET \
  --versioning-configuration Status=Enabled
```

**2. Point Terraform at it.** Fill in the `bucket` and `key` blanks in `terraform/backend.tf`. Note the comment on why these can't be variables.

**3. Migrate.** Re-running `init` after changing the backend moves the state you already have:

```bash
terraform init -migrate-state
```

Say `yes` when it offers to copy your local state to the new backend, then confirm:

```bash
aws s3 ls s3://$STATE_BUCKET --recursive
terraform state list
```

You should see everything from Part A — same resources, different home. Nothing in AWS changed; only the bookkeeping moved.

**4. Delete the local leftover.** Terraform leaves your old state behind as a backup; with S3 as the source of truth, a stale local copy is a liability:

```bash
rm terraform.tfstate.backup
```

Run `terraform plan` once more. **No changes** is proof that the runner, reading this same remote state, will see a deployed site rather than trying to build a second one.

## Part C: Give CI your credentials

The runner needs AWS credentials, and they can't be committed. GitHub stores them as **repository secrets**: write-only values, injected into a run as the workflow asks for them, and masked if a step ever prints one.

Add the same two keys you gave `aws configure`:

```bash
gh secret set AWS_ACCESS_KEY_ID
gh secret set AWS_SECRET_ACCESS_KEY
```

Each prompts for the value without echoing it. In the web UI: **Settings → Secrets and variables → Actions → New repository secret**, using those exact names. Verify the names — never the values, that's the point:

```bash
gh secret list
```

> Long-lived access keys in a repository are the simple answer, not the right one: they don't expire, and anyone who can push a workflow can use them. The production answer is OIDC — see the Tips.

## Part D: Write the pipeline

Open `.github/workflows/deploy.yml`. The skeleton checks out the repo, installs Terraform, configures AWS credentials, then runs `init`, `fmt -check`, `validate`, `plan`, and `apply`. Seven blanks, in five places, are yours to fill:

1. **`on.push.branches`** — which branch should deploy when something lands on it?
2. **`defaults.run.working-directory`** — every `run` step needs to start where the `.tf` files are.
3. **`aws-access-key-id` / `aws-secret-access-key`** — the two Part C secrets, as `${{ secrets.NAME }}`.
4. **The `terraform plan` command** — there's no terminal on a runner, so it must not stop to ask a human anything.
5. **The `terraform apply` step's `if:` and its command** — this is the one that matters. A plan is safe to run on anything; an apply must only happen on a real merge to the default branch, never on a pull request. (Hint: `github.event_name` and `github.ref`, where a branch ref looks like `refs/heads/main`.)

Read the `concurrency` block too — filled in for you, but it's there for a reason, and the Reflection asks about it.

**1. Open a pull request.** `git` wants the repo root, so step out of `terraform/` first:

```bash
cd ..
git switch -c add-pipeline
git add -A
git commit -m "Publish site with Terraform via GitHub Actions"
git push -u origin add-pipeline
gh pr create --fill
```

Watch the run:

```bash
gh pr checks --watch
gh run view --log
```

Read the log: `init`, `fmt`, `validate`, `plan` — and then the apply step **skipped**, because this is a pull request. The plan should report no changes, since Part A already applied everything by hand. That's a healthy plan: the repo and reality agree.

**2. Merge it.**

```bash
gh pr merge --squash --delete-branch
gh run watch
```

That pushes to `main`, which triggers the workflow again — and this time apply runs. It writes the live URL into the job summary, so the deployed address is recorded on the run itself rather than in someone's terminal:

```bash
gh run view --web
```

**3. Ship a change the way you will from now on.** Edit `site/index.html` on a branch — change the heading, or set that `build:` line to today's date:

```bash
git switch -c update-copy
git add site/index.html
git commit -m "Update homepage copy"
git push -u origin update-copy
gh pr create --fill
```

Look at the plan in the PR's check log: exactly one object updated in place, the `etag` changing from one hash to another. That's a reviewer being shown precisely what merging will do to production, before it happens. Merge it, let the apply run, and reload the site.

You did not touch AWS, and you did not run Terraform. You changed a file and merged a pull request.

## Reflection

You don't need to write these down, but you should be able to answer them:

- Part A and Part D deploy the same site with the same Terraform. What did moving the deploy into CI buy you — and what did it cost?
- Why must state be remote before CI can work at all? What specifically would have broken on the first run with `backend.tf` still pointing at a local file?
- Plans run on pull requests, applies only on `main`. Why is that split worth the extra `if:`? What could a stranger's pull request do if apply ran on `pull_request` too?
- You already had S3-backend locking from `use_lockfile`. Why does the workflow _also_ need `concurrency`? What does each protect against that the other doesn't?
- `aws s3 sync site/ s3://your-bucket/` uploads the same files in one line — no `for_each`, no `etag`. What does Terraform know after an apply that `sync` wouldn't, and what does each do when you _delete_ a file from `site/`?
- Someone changes the bucket policy by hand in the AWS console. Who finds out, and when?

## Tips

- **Run `terraform fmt` before you push.** The pipeline runs `fmt -check` and fails the job on formatting alone — deliberately, since it's the cheapest possible check, but an annoying way to find out.
- `terraform validate` catches config errors without touching AWS or needing credentials, so run it locally too.
- On Terraform 1.10 or older, `use_lockfile` won't work; locking used to need a separate DynamoDB table (`dynamodb_table` in the backend block), now deprecated. Upgrading is easier.
- `Error acquiring the state lock` means another apply is in flight, or one died holding the lock. Let it finish; if the lock is genuinely stale, `terraform force-unlock <ID>` releases it — read what it says first, and never run it while an apply is actually going.
- `gh run list`, `gh run view <id> --log`, and `gh run watch` keep you out of the browser; `gh run rerun <id>` retries a failed run.
- Debugging a workflow usually takes several commits that each fix one typo. That's expected; squash-merge and move on.
- A secret is masked in logs, but a workflow holding one is still editable by anyone with push access. The real-world fix is **OIDC**: GitHub hands AWS a short-lived signed token, AWS trades it for temporary credentials, and no long-lived key exists anywhere. In `aws-actions/configure-aws-credentials` that's `role-to-assume` plus `permissions: id-token: write` instead of the two keys you used here — worth reading once this lab makes sense.
- Consider **branch protection** on `main` (Settings → Rules) requiring the workflow's check to pass. A gate you can bypass by pushing straight to `main` isn't much of a gate.
- This lab needs `AmazonS3FullAccess`. If CI fails with `AccessDenied` but your laptop works, check that the secrets hold the right keys — `gh secret list` shows when each was last updated.

### Cleanup

**Always clean up when you're done.** Both buckets cost real (if tiny) money, and a public bucket left lying around is a liability.

```bash
cd terraform
terraform destroy
```

Then remove the state bucket. It's versioned, so emptying it means deleting every version, not just the current objects:

```bash
aws s3api delete-objects --bucket $STATE_BUCKET --delete "$(aws s3api list-object-versions \
  --bucket $STATE_BUCKET --query '{Objects: Versions[].{Key:Key,VersionId:VersionId}}' --output json)"
aws s3api delete-bucket --bucket $STATE_BUCKET
```

If it complains that the bucket still isn't empty, run the same command again with `DeleteMarkers[]` in place of `Versions[]` — deleting versioned objects leaves markers behind. (The S3 console's "Empty bucket" button handles both in one go.)

Finally, check the [S3 console](https://console.aws.amazon.com/s3/) for leftovers, and delete the two repository secrets (`gh secret delete AWS_ACCESS_KEY_ID`, same for the other) once the repo no longer needs to deploy.
