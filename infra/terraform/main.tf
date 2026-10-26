# Soundstage backend (architecture §16, m4.md T4.1, DECISIONS 26/10/26
# "Storage (M4)"): Firebase over project-soundstage — Auth (Identity
# Platform), Firestore for story metadata, a Firebase Storage bucket for
# documents and media, Hosting, and the security rules in ../firebase.
# Hard rule 7: resources are created here, never with `gcloud ... create`.

locals {
  services = [
    "cloudresourcemanager.googleapis.com",
    "serviceusage.googleapis.com",
    "firebase.googleapis.com",
    "firebasehosting.googleapis.com",
    "firebaserules.googleapis.com",
    "firebasestorage.googleapis.com",
    "firestore.googleapis.com",
    "identitytoolkit.googleapis.com",
    "apikeys.googleapis.com",
    "artifactregistry.googleapis.com",
    "cloudbuild.googleapis.com",
    "iam.googleapis.com",
    "run.googleapis.com",
    "secretmanager.googleapis.com",
    "storage.googleapis.com",
  ]
}

resource "google_project_service" "apis" {
  for_each           = toset(local.services)
  service            = each.value
  disable_on_destroy = false
}

# --- Terraform state ---------------------------------------------------------

resource "google_storage_bucket" "tfstate" {
  name                        = "${var.project_id}-tfstate"
  location                    = upper(var.region)
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"

  versioning {
    enabled = true
  }

  lifecycle {
    prevent_destroy = true
  }

  depends_on = [google_project_service.apis]
}

# --- Firebase ----------------------------------------------------------------

resource "google_firebase_project" "default" {
  provider   = google-beta
  project    = var.project_id
  depends_on = [google_project_service.apis]
}

resource "google_firebase_web_app" "soundstage" {
  provider        = google-beta
  project         = var.project_id
  display_name    = "Soundstage"
  deletion_policy = "DELETE"
  depends_on      = [google_firebase_project.default]
}

data "google_firebase_web_app_config" "soundstage" {
  provider   = google-beta
  project    = var.project_id
  web_app_id = google_firebase_web_app.soundstage.app_id
}

# --- Auth (Identity Platform) ------------------------------------------------

resource "google_identity_platform_config" "default" {
  project = var.project_id

  sign_in {
    allow_duplicate_emails = false

    email {
      enabled           = true
      password_required = true
    }

    phone_number {
      enabled = false
    }
  }

  authorized_domains = concat(var.auth_domains, [
    "${var.project_id}.firebaseapp.com",
    "${var.project_id}.web.app",
  ])

  depends_on = [google_firebase_project.default]
}

# --- Firestore: story metadata -----------------------------------------------

resource "google_firestore_database" "default" {
  project                 = var.project_id
  name                    = "(default)"
  location_id             = var.region
  type                    = "FIRESTORE_NATIVE"
  delete_protection_state = "DELETE_PROTECTION_ENABLED"
  deletion_policy         = "ABANDON"
  depends_on              = [google_firebase_project.default]
}

resource "google_firebaserules_ruleset" "firestore" {
  project = var.project_id

  source {
    files {
      name    = "firestore.rules"
      content = file("${path.module}/../firebase/firestore.rules")
    }
  }

  depends_on = [google_firestore_database.default]
}

resource "google_firebaserules_release" "firestore" {
  project      = var.project_id
  name         = "cloud.firestore"
  ruleset_name = google_firebaserules_ruleset.firestore.name

  lifecycle {
    replace_triggered_by = [google_firebaserules_ruleset.firestore]
  }
}

# --- Storage: documents and media --------------------------------------------

resource "google_storage_bucket" "media" {
  name                        = "${var.project_id}-media"
  location                    = upper(var.region)
  uniform_bucket_level_access = true

  # Media is read by the web player (CanvasKit/skwasm decode images from
  # bytes, which needs CORS). Access is granted by Firebase download tokens
  # and rules, not cookies, so any origin may GET.
  cors {
    origin          = ["*"]
    method          = ["GET", "HEAD"]
    response_header = ["Content-Type", "Content-Length", "Range"]
    max_age_seconds = 3600
  }

  lifecycle {
    prevent_destroy = true
  }

  depends_on = [google_project_service.apis]
}

resource "google_firebase_storage_bucket" "media" {
  provider   = google-beta
  project    = var.project_id
  bucket_id  = google_storage_bucket.media.id
  depends_on = [google_firebase_project.default]
}

resource "google_firebaserules_ruleset" "storage" {
  project = var.project_id

  source {
    files {
      name    = "storage.rules"
      content = file("${path.module}/../firebase/storage.rules")
    }
  }

  depends_on = [google_firebase_storage_bucket.media]
}

resource "google_firebaserules_release" "storage" {
  project      = var.project_id
  name         = "firebase.storage/${google_storage_bucket.media.name}"
  ruleset_name = google_firebaserules_ruleset.storage.name

  lifecycle {
    replace_triggered_by = [google_firebaserules_ruleset.storage]
  }
}

# Hosting: creating the Firebase project creates the default site
# (<project>.web.app); deploys go through `firebase deploy --only hosting`.
