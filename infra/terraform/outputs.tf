# The Firebase web config is public by design (it identifies the project;
# rules guard the data), but per hard rule 6 it is not committed: write it
# to the gitignored soundstage_platform/.env.firebase.json with
#   terraform output -json firebase_web_config > ../../soundstage_platform/.env.firebase.json
# and build with --dart-define-from-file.
output "firebase_web_config" {
  value = {
    FIREBASE_API_KEY             = data.google_firebase_web_app_config.soundstage.api_key
    FIREBASE_APP_ID              = google_firebase_web_app.soundstage.app_id
    FIREBASE_AUTH_DOMAIN         = data.google_firebase_web_app_config.soundstage.auth_domain
    FIREBASE_PROJECT_ID          = var.project_id
    FIREBASE_STORAGE_BUCKET      = google_storage_bucket.media.name
    FIREBASE_MESSAGING_SENDER_ID = data.google_firebase_web_app_config.soundstage.messaging_sender_id
  }
  sensitive = true
}

output "hosting_url" {
  value = "https://${var.project_id}.web.app"
}

output "media_bucket" {
  value = google_storage_bucket.media.name
}

output "tfstate_bucket" {
  value = google_storage_bucket.tfstate.name
}
