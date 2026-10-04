variable "game_servers_enabled" {
  description = "Provision the private production multiplayer infrastructure after reviewing its plan and bootstrap sequence."
  type        = bool
  default     = false
}

variable "game_server_owner_subjects" {
  description = "Cognito production subject IDs permitted to start a game server."
  type        = set(string)
  sensitive   = true
  default     = []
}

variable "game_server_instance_type" {
  description = "ARM candidate; validate 60 Hz performance with depleted Standard CPU credits before release."
  type        = string
  default     = "t4g.micro"
  validation {
    condition     = contains(["t4g.micro", "t4g.small"], var.game_server_instance_type)
    error_message = "Select t4g.micro or t4g.small after measuring capacity."
  }
}

variable "game_server_root_volume_gib" {
  description = "Encrypted retained gp3 root size; verify the selected AMI's snapshot minimum before applying."
  type        = number
  default     = 8
  validation {
    condition     = var.game_server_root_volume_gib >= 8 && var.game_server_root_volume_gib <= 32
    error_message = "Use an explicitly reviewed root size between 8 and 32 GiB."
  }
}

variable "game_server_certificate_email" {
  description = "ACME contact email; supply privately when multiplayer is enabled."
  type        = string
  sensitive   = true
  default     = ""
}

variable "game_server_https_cidrs" {
  description = "Inbound HTTPS/WSS clients; authentication and private invite codes are enforced by the application. No SSH is exposed."
  type        = set(string)
  default     = ["0.0.0.0/0"]
}
