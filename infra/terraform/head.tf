# Link previews (m4.md T4.3, DECISIONS 26/10/26 "Head metadata"): a small
# Dart service on Cloud Run serves the app shell for /s/<slug> with the
# story's title, description and cover image. Firebase Hosting rewrites
# /s/** to it and caches its replies on the CDN.
#
# Cost guard (user, 26/10/26: scale to zero, no non-trivial running cost):
# no minimum instances, at most 2, CPU only while serving a request,
# 256 MiB, 10 s timeout; the registry keeps the 3 newest images and build
# sources expire after 7 days.
#
# Deploying a new image:
#   gcloud builds submit services/head --config services/head/cloudbuild.yaml \
#     --substitutions _IMAGE=<head_image>:<tag> \
#     --service-account <builder_service_account> \
#     --gcs-source-staging-dir gs://<project>-builds/source --project <project>
#   terraform apply -var head_image_tag=<tag>   (then update the default)

locals {
  registry    = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.soundstage.repository_id}"
  head_image  = "${local.registry}/head"
  agent_image = "${local.registry}/agent"
}

resource "google_artifact_registry_repository" "soundstage" {
  location      = var.region
  repository_id = "soundstage"
  format        = "DOCKER"
  description   = "Soundstage service images."

  cleanup_policy_dry_run = false

  cleanup_policies {
    id     = "keep-newest"
    action = "KEEP"
    most_recent_versions {
      keep_count = 3
    }
  }

  cleanup_policies {
    id     = "delete-older"
    action = "DELETE"
    condition {
      tag_state  = "ANY"
      older_than = "604800s"
    }
  }

  depends_on = [google_project_service.apis]
}

resource "google_storage_bucket" "builds" {
  name                        = "${var.project_id}-builds"
  location                    = upper(var.region)
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = true

  lifecycle_rule {
    condition {
      age = 7
    }
    action {
      type = "Delete"
    }
  }

  depends_on = [google_project_service.apis]
}

# --- Build ---------------------------------------------------------------------

resource "google_service_account" "builder" {
  account_id   = "soundstage-builder"
  display_name = "Soundstage image builds"
  depends_on   = [google_project_service.apis]
}

resource "google_artifact_registry_repository_iam_member" "builder_push" {
  location   = google_artifact_registry_repository.soundstage.location
  repository = google_artifact_registry_repository.soundstage.name
  role       = "roles/artifactregistry.writer"
  member     = google_service_account.builder.member
}

resource "google_storage_bucket_iam_member" "builder_sources" {
  bucket = google_storage_bucket.builds.name
  role   = "roles/storage.objectViewer"
  member = google_service_account.builder.member
}

resource "google_project_iam_member" "builder_logs" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = google_service_account.builder.member
}

# --- Service -------------------------------------------------------------------

resource "google_service_account" "head" {
  account_id   = "soundstage-head"
  display_name = "Soundstage link previews and reader gate"
  depends_on   = [google_project_service.apis]
}

# Reads records; writes gate secrets (gates/{id}, m7.md T7.4).
resource "google_project_iam_member" "head_firestore" {
  project = var.project_id
  role    = "roles/datastore.user"
  member  = google_service_account.head.member
}

# The gate streams gated files (Storage gated/…) to readers with a pass.
resource "google_storage_bucket_iam_member" "head_media" {
  bucket = google_storage_bucket.media.name
  role   = "roles/storage.objectViewer"
  member = google_service_account.head.member
}

# The key that signs readers' passes. Generated here, kept in Secret
# Manager (and the private Terraform state), never in a file.
resource "random_password" "gate_key" {
  length  = 48
  special = false
}

resource "google_secret_manager_secret" "gate_key" {
  secret_id = "soundstage-gate-key"

  replication {
    auto {}
  }

  depends_on = [google_project_service.apis]
}

resource "google_secret_manager_secret_version" "gate_key" {
  secret      = google_secret_manager_secret.gate_key.id
  secret_data = random_password.gate_key.result
}

resource "google_secret_manager_secret_iam_member" "head_gate_key" {
  secret_id = google_secret_manager_secret.gate_key.id
  role      = "roles/secretmanager.secretAccessor"
  member    = google_service_account.head.member
}

resource "google_cloud_run_v2_service" "head" {
  name                = "soundstage-head"
  location            = var.region
  ingress             = "INGRESS_TRAFFIC_ALL"
  deletion_protection = false

  template {
    service_account = google_service_account.head.email
    # Previews answer in well under a second; gated video streams longer.
    timeout                          = "300s"
    max_instance_request_concurrency = 80

    scaling {
      min_instance_count = 0
      max_instance_count = 2
    }

    containers {
      image = "${local.head_image}:${var.head_image_tag}"

      resources {
        limits = {
          cpu    = "1"
          memory = "256Mi"
        }
        cpu_idle          = true
        startup_cpu_boost = false
      }

      env {
        name  = "SITE_ORIGIN"
        value = "https://${var.project_id}.web.app"
      }
      env {
        name  = "PROJECT_ID"
        value = var.project_id
      }
      env {
        name  = "FIREBASE_API_KEY"
        value = data.google_firebase_web_app_config.soundstage.api_key
      }
      env {
        name  = "MEDIA_BUCKET"
        value = google_storage_bucket.media.name
      }
      env {
        name  = "ALLOWED_ORIGINS"
        value = "https://${var.project_id}.web.app,https://${var.project_id}.firebaseapp.com"
      }
      env {
        name = "GATE_KEY"
        value_source {
          secret_key_ref {
            secret  = google_secret_manager_secret.gate_key.secret_id
            version = "latest"
          }
        }
      }
    }
  }

  depends_on = [
    google_project_iam_member.head_firestore,
    google_storage_bucket_iam_member.head_media,
    google_secret_manager_secret_iam_member.head_gate_key,
    google_secret_manager_secret_version.gate_key,
  ]
}

# Hosting calls the service unauthenticated (required for Hosting rewrites).
resource "google_cloud_run_v2_service_iam_member" "head_public" {
  name     = google_cloud_run_v2_service.head.name
  location = google_cloud_run_v2_service.head.location
  role     = "roles/run.invoker"
  member   = "allUsers"
}
