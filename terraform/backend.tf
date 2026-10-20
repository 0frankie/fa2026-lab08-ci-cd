# Up to now Terraform has kept its state in terraform.tfstate, next to this
# file, on your laptop. A GitHub Actions runner boots with an empty disk and
# a fresh `git clone` — and .gitignore (rightly) keeps state out of the
# repo. A runner with no state has no idea your bucket exists, so it would
# try to create it again, and fail.
#
# A *remote backend* fixes that: state lives in S3, where both you and every
# CI run can read and write the same copy of it.
#
# TODO: fill in the two blanks below, then run `terraform init -migrate-state`.
terraform {
  backend "s3" {
    # Backend configuration can't use variables or interpolation — Terraform
    # has to find its state before it has read enough of your config to know
    # what a variable is. Both values below are literal strings, which is
    # also why the state bucket gets created by hand in Part B rather than by
    # Terraform.

    # The state bucket you created, e.g. "lab09-<your-pennkey>-tfstate".
    bucket = "lab09-flin0-tfstate"

    # Path to the state file inside that bucket, e.g.
    # "lab-09/terraform.tfstate". One bucket can hold the state of many
    # projects, kept apart by this key.
    key = "lab-09/terraform.tfstate"

    region = "us-east-1"
    use_lockfile = true
  }
}
