# Invite-only access (DECISIONS 26/10/26 "Invites", m7.md T7.1). The admin
# keeps the approved emails in Firestore `config/invites` (field `emails`,
# lowercase) by hand in the console; Terraform only creates the document
# and leaves its contents alone afterwards. Rules (infra/firebase) and the
# agent service read it.

data "google_project" "this" {
  project_id = var.project_id
}

resource "google_firestore_document" "invites" {
  project     = var.project_id
  database    = google_firestore_database.default.name
  collection  = "config"
  document_id = "invites"
  fields      = jsonencode({ emails = { arrayValue = {} } })

  lifecycle {
    ignore_changes = [fields]
  }
}

# Storage rules read config/invites (cross-service rules): the Rules
# service agent needs Firestore read access.
resource "google_project_iam_member" "rules_firestore" {
  project = var.project_id
  role    = "roles/firebaserules.firestoreServiceAgent"
  member  = "serviceAccount:service-${data.google_project.this.number}@firebase-rules.iam.gserviceaccount.com"
}

# The agent service checks the invite list too.
resource "google_project_iam_member" "agent_firestore" {
  project = var.project_id
  role    = "roles/datastore.viewer"
  member  = google_service_account.agent.member
}
