# Custom domains (DECISIONS 26/10/26 "Custom domains", m7.md T7.5):
# premium and request-only. The admin lists the enabled authors' emails in
# Firestore `config/premium` (field `emails`) by hand; the agent service
# connects their domains to a second Hosting site, "pages", whose every
# path goes to the head service (previews at the handle's clean paths).
# The main site stays as it is. Firebase Hosting provisions certificates;
# a site holds a limited number of custom domains, so more sites (or a
# reverse proxy) come later.

resource "google_firebase_hosting_site" "pages" {
  provider   = google-beta
  project    = var.project_id
  site_id    = "${var.project_id}-pages"
  depends_on = [google_firebase_project.default]
}

resource "google_firestore_document" "premium" {
  project     = var.project_id
  database    = google_firestore_database.default.name
  collection  = "config"
  document_id = "premium"
  fields      = jsonencode({ emails = { arrayValue = {} } })

  lifecycle {
    ignore_changes = [fields]
  }
}

# The agent service creates and removes custom domains on the pages site.
resource "google_project_iam_member" "agent_hosting" {
  project = var.project_id
  role    = "roles/firebasehosting.admin"
  member  = google_service_account.agent.member
}
