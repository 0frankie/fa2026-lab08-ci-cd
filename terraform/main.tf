terraform {
  # The S3 backend's built-in locking (`use_lockfile` in backend.tf) went
  # GA in Terraform 1.11. Pinning a floor here means CI can't quietly run an
  # older version than you do.
  required_version = ">= 1.11"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

# Notice what's *missing* compared to Lab 06: there's no `profile =
# "cis1912"` line. A named profile is a thing on your laptop — the GitHub
# Actions runner has no ~/.aws/credentials to read one out of. With no
# profile pinned here, the AWS provider falls back to the standard AWS
# environment variables, which both you (`export AWS_PROFILE=...`) and the
# runner (repository secrets, Part C) can supply. Same code, two
# environments, no "works on my machine."
provider "aws" {
  region = var.aws_region
}

resource "aws_s3_bucket" "main" {
  bucket = var.bucket_name
}

resource "aws_s3_bucket_website_configuration" "main" {
  bucket = aws_s3_bucket.main.id

  index_document {
    suffix = "index.html"
  }
}

resource "aws_s3_bucket_public_access_block" "main" {
  bucket = aws_s3_bucket.main.id

  block_public_acls       = false
  block_public_policy     = false
  ignore_public_acls      = false
  restrict_public_buckets = false
}

# Same resources, and the same explicit depends_on, as Lab 06 — a public
# policy is rejected while the bucket is still blocking public policies, and
# nothing in the policy JSON tells Terraform that.
resource "aws_s3_bucket_policy" "main" {
  bucket     = aws_s3_bucket.main.id
  depends_on = [aws_s3_bucket_public_access_block.main]

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "PublicReadGetObject"
        Effect    = "Allow"
        Principal = "*"
        Action    = "s3:GetObject"
        Resource  = "${aws_s3_bucket.main.arn}/*"
      }
    ]
  })
}

locals {
  site_dir = "${path.module}/../site"

  # S3 serves whatever Content-Type the object was uploaded with. Get this
  # wrong and the browser downloads your page instead of rendering it, so
  # the pipeline has to set it per file rather than per upload command.
  content_types = {
    ".html" = "text/html"
    ".css"  = "text/css"
    ".js"   = "text/javascript"
    ".svg"  = "image/svg+xml"
    ".png"  = "image/png"
    ".ico"  = "image/x-icon"
  }
}

# Lab 06 uploaded one page whose HTML was written inline in the .tf file.
# That doesn't scale to a real site, and it isn't what you'd want anyway:
# the site's content should be files in the repo that anyone can edit,
# published by the pipeline.
#
# `for_each` turns this one block into one managed resource per file under
# ../site, so `terraform state list` ends up with
# aws_s3_object.site["index.html"], aws_s3_object.site["style.css"], and so
# on. Add a file to site/ and the next apply creates a matching object;
# delete one and the next apply deletes the object too.
#
# TODO: fill in the two blanks below.
resource "aws_s3_object" "site" {
  # Which files should this resource be created for? You want every file
  # under local.site_dir, at any depth.
  # Hint: fileset() walks a directory at plan time and returns relative
  # paths ("index.html", "assets/logo.svg"). "**" matches at any depth.
  for_each = fileset("${local.site_dir}", "**")

  bucket       = aws_s3_bucket.main.id
  key          = each.value
  source       = "${local.site_dir}/${each.value}"
  content_type = lookup(local.content_types, try(regex("\\.[^.]+$", each.value), ""), "application/octet-stream")

  # Without this, the only thing Terraform tracks about an object is that it
  # exists. Edit site/index.html, run `terraform plan`, and it reports "no
  # changes" — your pipeline goes green and the live site stays stale, which
  # is a genuinely awful bug to debug.
  #
  # An ETag is S3's checksum of the object's contents. Setting it to a hash
  # of the local file is what makes a content change show up as a diff.
  # Hint: filemd5() takes a path and returns that file's MD5.
  etag = filemd5("${local.site_dir}/${each.value}")
}

output "website_url" {
  value = "http://${aws_s3_bucket_website_configuration.main.website_endpoint}"
}

output "bucket_name" {
  value = aws_s3_bucket.main.id
}

output "published_files" {
  description = "Every file the pipeline currently has published."
  value       = sort(keys(aws_s3_object.site))
}
