variable "name" {
  description = "Key pair name (also the local file name)."
  type        = string
}

variable "region" {
  type = string
}

variable "tags" {
  type    = map(string)
  default = {}
}

variable "output_dir" {
  description = "Local directory where the private/public key files are written."
  type        = string
}
