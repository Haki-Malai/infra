variable "region" { type = string }
variable "name" { type = string }
variable "hostname" { type = string }
variable "zone_id" { type = string }
variable "vpc_cidr" { type = string }
variable "instance_type" { type = string }
variable "root_volume_gib" { type = number }
variable "https_cidrs" { type = set(string) }
variable "certificate_email" {
  type      = string
  sensitive = true
}
variable "artifacts_bucket" { type = string }
variable "artifacts_bucket_arn" { type = string }
variable "management_key" { type = string }
variable "management_sha256" { type = string }
variable "control_table" { type = string }
variable "control_table_arn" { type = string }
variable "results_table" { type = string }
variable "results_table_arn" { type = string }
variable "tickets_table" { type = string }
variable "tickets_table_arn" { type = string }
variable "site_origin" { type = string }
variable "tags" { type = map(string) }
