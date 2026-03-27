variable "repository_names" {
  description = "List of repository names to create"
  type        = list(string)
}

variable "project_name" {
  description = "Project prefix for repository names"
  type        = string
}

variable "image_retention_count" {
  description = "Number of images to keep per repository"
  type        = number
  default     = 5
}
