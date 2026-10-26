# State lives in the versioned bucket this configuration creates
# (google_storage_bucket.tfstate); the first apply ran with local state and
# was migrated with `terraform init -migrate-state`.
terraform {
  backend "gcs" {
    bucket = "project-soundstage-tfstate"
    prefix = "soundstage"
  }
}
