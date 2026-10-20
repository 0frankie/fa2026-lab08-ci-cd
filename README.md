# Lab 09: CI/CD with GitHub Actions

In Lab 06 you deployed a website with Terraform, and in Lab 07 you deployed a function with Pulumi. Both times, the thing that actually ran the deploy was _you_, sitting at your laptop, typing `apply` and then typing `yes`. The infrastructure was code, but the deployment was still a person.

That breaks down fast. The state file lives on one laptop, so you're the only one who can deploy. Nobody reviews what you're about to apply, because the plan scrolls past in your terminal and then it's gone. And nothing stops the gap between "merged to main" and "live in production" from drifting — the repo says one thing, the bucket says another, and the only record of what actually got deployed is your shell history.

**CI/CD** closes that gap by moving the deploy into the repo. A pull request produces a `terraform plan` that a reviewer can read; a merge to `main` produces a `terraform apply` that nobody has to remember to run. In this lab you'll take the Lab 06 S3 website, grow it into a real multi-file site published by Terraform, move Terraform's state somewhere a CI runner can reach it, and then write the **GitHub Actions** workflow that deploys it on every merge.

Like Lab 06 and Lab 07, this lab runs against a **real AWS account**. The resources are effectively free at this scale (an S3 bucket, a second small bucket for state, a handful of tiny objects), but they are real: follow the cleanup steps at the end, and never commit your AWS credentials.

## Setup

You'll need:

- **[Terraform CLI](https://developer.hashicorp.com/terraform/install)** — `brew install terraform` on macOS. This lab needs **1.11 or newer** (the S3 backend's built-in state locking went GA there). Check with `terraform version` and run `brew upgrade terraform` if you're behind.
- **[AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html)** — `brew install awscli`.
- **[GitHub CLI](https://cli.github.com/)** (optional but handy) — `brew install gh`, then `gh auth login`. Everything below can also be done through the GitHub web UI.
- A GitHub account, and **a repository you own** — see below.

### AWS credentials

Same credentials as Lab 06 and Lab 07 — check your inbox if you don't have them. Configure them under a named profile:

```bash
aws configure --profile cis1912
```

Enter your Access Key ID, Secret Access Key, `us-east-1` for the region, and `json` for the output format.

Unlike Lab 06, `main.tf` here does **not** name a profile. Point your shell at it instead:

```bash
export AWS_PROFILE=cis1912
```

```bash
aws sts get-caller-identity
```

You should see your account ID and IAM user ARN. (That `export` lasts only for the current terminal session — if you open a new tab, run it again.)

Why the difference? A named profile is a file on your laptop. The GitHub Actions runner has no `~/.aws/credentials` to read one out of, so pinning `profile = "cis1912"` in `main.tf` would mean the same code works for you and fails in CI. With no profile pinned, the AWS provider falls back to the standard `AWS_*` environment variables — which you supply with `export AWS_PROFILE`, and which CI will supply from repository secrets. One config, two environments.

### Your own repository

GitHub Actions runs workflows out of the repository they're committed to, and only a repo admin can add the secrets this lab needs. So this lab has to live in **your** repo, not the course one.

Push this directory to a new repository under your own account:

```bash
gh repo create lab-09-ci-cd --private --source=. --remote=origin --push
```

Or create an empty private repo on github.com and follow its "push an existing repository" instructions. Either way, confirm it worked:

```bash
git remote -v
gh repo view --web
```

## Part A: Publish the site from your laptop

Before automating a deploy, you should be able to do it by hand — if you can't, you're automating something you don't understand yet.

Look at what's here:

- `site/` — the actual website: `index.html` and `style.css`. Plain files in the repo, editable by anyone, no HTML buried inside a `.tf` file.
- `terraform/main.tf` — the bucket, website configuration, public access block, and bucket policy from Lab 06, plus one new resource that publishes everything in `site/`.
- `terraform/variables.tf` and `terraform/terraform.tfvars` — the bucket name, pulled out into config.
- `terraform/backend.tf` — where Terraform keeps its state. Ignore it until Part B.
- `.github/workflows/deploy.yml` — the pipeline. Ignore it until Part D.

**1. Name your bucket.** Open `terraform/terraform.tfvars` and fill in the `<FILL_IN>`. S3 bucket names are global across all of AWS, so use something like `lab09-<your-pennkey>-website`.

**2. Publish the site directory.** Open `terraform/main.tf` and find `aws_s3_object.site`. Lab 06 uploaded exactly one object whose HTML was written inline; this resource uses `for_each` to manage one object per file in `site/`. Two blanks to fill:

- `for_each` — the set of files to publish. You want every file under `local.site_dir`, at any depth. (Hint: `fileset()`, and `"**"` as the pattern.)
- `etag` — a hash of each file's contents, so that _changing_ a file shows up as a change Terraform wants to apply. (Hint: `filemd5()`.)

Read the comments above both blanks; the `etag` one in particular is a bug you will eventually hit in a real pipeline.

**3. Deploy.** Terraform is still using local state at this point, which is fine for now:

```bash
cd terraform
terraform init
terraform plan
```

The plan should show the bucket, its three configuration resources, and **one `aws_s3_object.site[...]` per file in `site/`**. If you only see one object, or none, revisit your `for_each`.

```bash
terraform apply
```

Type `yes`. Then open it:

```bash
curl $(terraform output -raw website_url)
```

Open that URL in a browser too — you should get a styled page, which also tells you the `style.css` object went up with the right `content_type`.

**4. Watch `etag` do its job.** Edit `site/index.html` (that's `../site/index.html` from where your shell is) and change the `build: unknown` line to say something else. Then:

```bash
terraform plan
```

Terraform should report **one object to update, in place**. That diff exists only because of `etag`: without it, the only fact in state is that an object named `index.html` exists, which is still true, so Terraform would report "no changes" and your edit would never ship. Apply it and curl again to confirm the new text is live.

> If you want to see that failure for yourself, comment out the `etag` line, run `terraform apply`, edit the HTML, and run `terraform plan` again. A green pipeline deploying nothing is a genuinely nasty bug. Put `etag` back when you're done.

**Don't destroy anything yet** — Part B moves this deployment's state, and Part D hands it over to CI.

## Part B: Move the state off your laptop

You should still be in `terraform/` from Part A. Look at what you have right now:

```bash
ls terraform.tfstate
```

That file is the only record of what Terraform created. A GitHub Actions runner starts from a fresh `git clone` on an empty disk, and `.gitignore` (correctly) keeps state out of git — so a runner would have no state at all, decide your bucket doesn't exist, try to create it, and fail with `BucketAlreadyOwnedByYou`.

The fix is a **remote backend**: keep state in S3, where you and every CI run read and write the same copy.

**1. Create the state bucket by hand.** Terraform can't create the bucket that holds its own state — it would have to read its state to know whether the bucket exists. This chicken-and-egg bootstrap is normal and you only do it once:

```bash
export STATE_BUCKET=lab09-<your-pennkey>-tfstate
aws s3api create-bucket --bucket $STATE_BUCKET --region us-east-1
```

Turn on versioning, so a bad write doesn't leave you with no way back:

```bash
aws s3api put-bucket-versioning --bucket $STATE_BUCKET \
  --versioning-configuration Status=Enabled
```

**2. Point Terraform at it.** Open `terraform/backend.tf` and fill in the `bucket` and `key` blanks. Note the comment about why these can't be variables.

**3. Migrate.** Re-running `init` after changing the backend tells Terraform to move the state it already has:

```bash
terraform init -migrate-state
```

Terraform will ask whether to copy your existing local state to the new backend. Say `yes`. Confirm it landed:

```bash
aws s3 ls s3://$STATE_BUCKET --recursive
terraform state list
```

`terraform state list` should still show everything from Part A — same resources, different home. Nothing in AWS changed; only the bookkeeping moved.

**4. Delete the local leftover.** Terraform leaves your old state behind as a backup. Now that S3 is the source of truth, a stale local copy is a liability:

```bash
rm terraform.tfstate.backup
```

Run `terraform plan` once more. It should report **no changes** — proof that the runner, reading this same remote state, will also see a fully-deployed site rather than trying to build a second one.

## Part C: Give CI your credentials

The runner needs AWS credentials, and they obviously can't be committed. GitHub stores them as **repository secrets**: write-only values, injected into a workflow run as the workflow asks for them, and masked if a step ever prints one.

Add your two keys — the same Access Key ID and Secret Access Key you gave `aws configure`:

```bash
gh secret set AWS_ACCESS_KEY_ID
gh secret set AWS_SECRET_ACCESS_KEY
```

Each command prompts for the value and does not echo it. Through the web UI, it's **Settings → Secrets and variables → Actions → New repository secret**; use those exact names.

Verify the names (never the values — that's the point):

```bash
gh secret list
```

> Long-lived access keys in a repository are the simple answer, not the right one: they don't expire, and anyone who can push a workflow can use them. The production answer is OIDC — see the Tips.

## Part D: Write the pipeline

Open `.github/workflows/deploy.yml`. The skeleton is there: check out the repo, install Terraform, configure AWS credentials, `init`, `fmt -check`, `validate`, `plan`, and `apply`. Seven blanks, in five places, are yours to fill:

1. **`on.push.branches`** — which branch should deploy when something lands on it?
2. **`defaults.run.working-directory`** — every `run` step needs to start where the `.tf` files are.
3. **`aws-access-key-id` / `aws-secret-access-key`** — reference the two secrets from Part C. The syntax is `${{ secrets.NAME }}`.
4. **The `terraform plan` command** — there's no terminal on a runner, so it must not stop to ask a human anything.
5. **The `terraform apply` step's `if:` and its command** — this is the one that matters. A plan is safe to run on anything; an apply must only happen on a real merge to the default branch, never on a pull request. (Hint: `github.event_name` and `github.ref`, where a branch ref looks like `refs/heads/main`.)

Read the `concurrency` block too. It's filled in for you, but it's there for a reason, and the Reflection asks about it.

**1. Open a pull request.** Put your workflow (and your Part A/B edits) on a branch — `git` wants the repo root, so step back out of `terraform/` first:

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

Read the log. It should `init`, `fmt`, `validate`, and `plan` — and then **skip the apply step**, because this is a pull request. The plan should report no changes, since you already applied everything by hand in Part A. That's a healthy plan: the repo and reality agree.

**2. Merge it.**

```bash
gh pr merge --squash --delete-branch
```

This pushes to `main`, which triggers the workflow again — and this time the apply step runs. Watch it:

```bash
gh run watch
```

When it finishes, open the run's summary page in GitHub. The apply step writes the live URL into the job summary, so the deployed address is recorded on the run itself rather than living only in someone's terminal:

```bash
gh run view --web
```

**3. Ship a change the way you will from now on.** Edit `site/index.html` — change the heading, or set that `build:` line to today's date — on a branch:

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

You don't need to write this down, but you should be able to answer if asked:

- Part A and Part D deploy the same site with the same Terraform. What did moving the deploy into CI actually buy you — and what did it cost?
- Why does state have to be remote before CI can work at all? What specifically would have gone wrong on the first run if `backend.tf` still pointed at a local file?
- A plan runs on pull requests, but an apply only runs on `main`. Why is that split worth the extra `if:`? What could a stranger's pull request do if `apply` ran on `pull_request` too?
- You already had S3-backend locking from `use_lockfile`. Why does the workflow _also_ have a `concurrency` block? What does each one protect against that the other doesn't?
- `aws s3 sync site/ s3://your-bucket/` would have uploaded the same files in one line, no `for_each`, no `etag`. What does Terraform know after an apply that `aws s3 sync` wouldn't — and what happens with each approach when you _delete_ a file from `site/`?
- Someone changes the bucket policy by hand in the AWS console. Who finds out, and when?

## Tips

- **Run `terraform fmt` before you push.** The pipeline runs `terraform fmt -check`, which fails the job on formatting alone. That's deliberate — it's the cheapest possible CI check — but it's an annoying way to find out.
- `terraform validate` catches config errors without touching AWS or needing credentials, so it's worth running locally too.
- If you're stuck on Terraform 1.10 or older, `use_lockfile` won't work; locking used to require a separate DynamoDB table (`dynamodb_table` in the backend block), which is now deprecated. Upgrading is easier.
- If a run fails with `Error acquiring the state lock`, another apply is in flight (or one died holding the lock). Let it finish; if the lock is genuinely stale, `terraform force-unlock <ID>` releases it — read what it says first, and never run it while another apply is actually going.
- `gh run list`, `gh run view <id> --log`, and `gh run watch` keep you out of the browser. `gh run rerun <id>` retries a failed run.
- Debugging a workflow usually means several commits that each only fix a typo. That's expected; squash-merge and move on.
- A secret is masked in logs, but a workflow with a secret is still a workflow anyone with push access can edit. The real-world fix is **OIDC**: GitHub hands AWS a short-lived signed token, AWS trades it for temporary credentials, and no long-lived key exists anywhere. In `aws-actions/configure-aws-credentials` that's `role-to-assume` plus `permissions: id-token: write` instead of the two keys you used here — worth reading about once this lab makes sense.
- Consider adding **branch protection** on `main` (Settings → Rules) requiring the workflow's check to pass. A pipeline that can be bypassed by pushing straight to `main` isn't much of a gate.
- This lab needs `AmazonS3FullAccess`. If CI fails with `AccessDenied` but your laptop works, check that the secrets hold the right keys — `gh secret list` shows when each was last updated.

### Cleanup

**Always clean up when you're done.** Both buckets cost real (if tiny) money, and a public bucket left lying around is a liability.

Tear down the website:

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

If it complains that the bucket still isn't empty, run the same command again with `DeleteMarkers[]` in place of `Versions[]` — deleting versioned objects leaves markers behind. (The S3 console's "Empty bucket" button handles both in one go, if you'd rather.)

Finally, check the [S3 console](https://console.aws.amazon.com/s3/) for leftovers, and delete the two repository secrets (`gh secret delete AWS_ACCESS_KEY_ID`, same for the other) once the repo no longer needs to deploy.
