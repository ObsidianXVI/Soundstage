variable "project_id" {
  description = "The Soundstage GCP project."
  type        = string
  default     = "project-soundstage"
}

variable "region" {
  description = "Default region (Firestore, buckets)."
  type        = string
  default     = "us-central1"
}

variable "auth_domains" {
  description = "Domains allowed to sign in (besides the Firebase Hosting ones)."
  type        = list(string)
  default     = ["localhost", "127.0.0.1"]
}

variable "head_image_tag" {
  description = "Tag of the soundstage-head image in Artifact Registry (built with services/head/cloudbuild.yaml)."
  type        = string
  default     = "v3"
}

variable "agent_image_tag" {
  description = "Tag of the soundstage-agent image in Artifact Registry (built with services/agent/cloudbuild.yaml)."
  type        = string
  default     = "v1"
}
