# The agent service (m6.md "Architecture", DECISIONS 26/10/26 #7): authors'
# model API keys live in Secret Manager (one secret per author and
# provider, created and read only by this service) and are used only to
# forward that author's agent requests. Called directly by the app with
# CORS: Hosting rewrites end requests at 60 s, too short for model calls.
#
# Cost guard (as head.tf): no minimum instances, at most 2, CPU only while
# serving, 256 MiB; requests up to 300 s for long model replies. Model usage
# is billed to the author's own key.
#
# Deploying a new image: as head.tf, with services/agent and
# agent_image_tag.

resource "google_service_account" "agent" {
  account_id   = "soundstage-agent"
  display_name = "Soundstage agent (author keys, model requests)"
  depends_on   = [google_project_service.apis]
}

# The only secrets in the project are the agent's (agent-<uid>-<provider>).
resource "google_project_iam_member" "agent_secrets" {
  project = var.project_id
  role    = "roles/secretmanager.admin"
  member  = google_service_account.agent.member
}

resource "google_cloud_run_v2_service" "agent" {
  name                = "soundstage-agent"
  location            = var.region
  ingress             = "INGRESS_TRAFFIC_ALL"
  deletion_protection = false

  template {
    service_account                  = google_service_account.agent.email
    timeout                          = "300s"
    max_instance_request_concurrency = 40

    scaling {
      min_instance_count = 0
      max_instance_count = 2
    }

    containers {
      image = "${local.agent_image}:${var.agent_image_tag}"

      resources {
        limits = {
          cpu    = "1"
          memory = "256Mi"
        }
        cpu_idle          = true
        startup_cpu_boost = false
      }

      env {
        name  = "PROJECT_ID"
        value = var.project_id
      }
      # The web API key is public by design (it identifies the project; the
      # service uses it to check authors' ID tokens).
      env {
        name  = "FIREBASE_API_KEY"
        value = data.google_firebase_web_app_config.soundstage.api_key
      }
      env {
        name  = "PAGES_SITE"
        value = google_firebase_hosting_site.pages.site_id
      }
      env {
        name  = "ALLOWED_ORIGINS"
        value = "https://${var.project_id}.web.app,https://${var.project_id}.firebaseapp.com"
      }
    }
  }

  depends_on = [google_project_iam_member.agent_secrets]
}

# Authors call it from the browser; every request is checked against the
# author's Firebase ID token inside the service.
resource "google_cloud_run_v2_service_iam_member" "agent_public" {
  name     = google_cloud_run_v2_service.agent.name
  location = google_cloud_run_v2_service.agent.location
  role     = "roles/run.invoker"
  member   = "allUsers"
}
