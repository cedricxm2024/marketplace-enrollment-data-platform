# The AWS provider = the plugin that talks to AWS APIs
provider "aws" {
  region = var.aws_region

  # Every resource automatically gets these tags (cost tracking + ownership)
  default_tags {
    tags = local.common_tags
  }
}