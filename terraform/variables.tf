variable "bucket_name" {
  description = "Globally unique name for the website bucket."
  type        = string
}

variable "aws_region" {
  description = "Region to create the bucket in. Must match the region in backend.tf."
  type        = string
  default     = "us-east-1"
}
