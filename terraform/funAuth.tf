variable "org_name" {}
variable "base_url" {}
variable "api_token" {}

terraform {
  required_providers {
    okta = {
      source  = "okta/okta"
      version = "~> 3.28.0"
    }
  }
}
provider "okta" {
  org_name  = var.org_name
  base_url  = var.base_url
  api_token = var.api_token
}
resource "okta_group" "funauth_admins" {
  name        = "FunAuth.Admins"
  description = "Users in this group are granted admin access to FunAuth"
}
resource "okta_group" "funauth_users" {
  name        = "FunAuth.Users"
  description = "Users in this group are regular FunAuth users"
}
resource "okta_app_oauth" "funauth_oidc" {
  label       = "FunAuth Lab"
  type        = "browser"
  response_types = ["code"]
  issuer_mode    = "CUSTOM_URL"
  token_endpoint_auth_method = "none" # enables PKCE
  grant_types = [
      "authorization_code",
      "interaction_code",
      "refresh_token"
  ]
  redirect_uris = [
    "http://localhost:8080/"
  ]
  post_logout_redirect_uris = [
      "http://localhost:8080/"
  ]
  lifecycle {
     ignore_changes = [groups]
  }
}
# create the custom field for app role
resource "okta_app_user_schema_property" "funauth_app_role" {
  app_id = okta_app_oauth.funauth_oidc.id
  index = "funAuthRole"
  title = "FunAuth Role"
  type = "string"
  description = "Pick list for funAuth app role"
  master = "OKTA"
  scope = "NONE"
  permissions = "READ_WRITE"
  enum = [
    "ADMIN",
    "USER"
  ]
  one_of {
    const = "ADMIN"
    title = "Admin"
  }
  one_of {
    const = "USER"
    title = "User"
  }
}
# Create the App Assignment
resource "okta_app_group_assignment" "admin" {
  app_id   = okta_app_oauth.funauth_oidc.id
  group_id = okta_group.funauth_admins.id
  priority = 1
  depends_on = [
    okta_app_user_schema_property.funauth_app_role
  ]
  profile = jsonencode(
  {
    "funAuthRole": "ADMIN"
  }
  )
}
resource "okta_app_group_assignment" "users" {
  app_id   = okta_app_oauth.funauth_oidc.id
  group_id = okta_group.funauth_users.id
  priority = 2
  depends_on = [
    okta_app_user_schema_property.funauth_app_role
  ]
  profile = jsonencode(
  {
    "funAuthRole": "USER"
  }
  )
}
resource "okta_trusted_origin" "funauth_http" {
  name   = "FunAuth HTTP"
  origin = "http://localhost:8080"
  scopes = ["REDIRECT", "CORS"]
}
resource "okta_inline_hook" "token-hook" {
  name    = "Token Example"
  version = "1.0.0"
  type    = "com.okta.oauth2.tokens.transform"
  channel = {
    version = "1.0.0"
    uri     = "https://g4pywy3jvd.execute-api.us-east-2.amazonaws.com/token_hook"
    method  = "POST"
  }
  # auth = {
  #   key   = "Authorization"
  #   type  = "HEADER"
  #   value = "secret"
  # }
}
resource "okta_auth_server" "funauth_authz" {
  name        = "FunAuth"
  description = "Generated by Terraform"
  audiences   = ["api://funAuth"]
  credentials_rotation_mode = "AUTO"
  issuer_mode = "CUSTOM_URL"
}
resource "okta_auth_server_policy" "funauth_policy" {
  auth_server_id   = okta_auth_server.funauth_authz.id
  status           = "ACTIVE"
  name             = "standard"
  description      = "Generated by Terraform"
  priority         = 1
  client_whitelist = ["${okta_app_oauth.funauth_oidc.id}"]
}
resource "okta_auth_server_policy_rule" "funauth_policy_rule" {
  auth_server_id       = okta_auth_server.funauth_authz.id
  policy_id            = okta_auth_server_policy.funauth_policy.id
  status               = "ACTIVE"
  name                 = "one_hour"
  priority             = 1
  #group_whitelist      = ["${data.okta_group.all.id}"]
  group_whitelist = [
    okta_group.funauth_admins.id,
    okta_group.funauth_users.id,
  ]
  grant_type_whitelist = ["authorization_code", "interaction_code"]
  scope_whitelist      = ["*"]
  inline_hook_id = okta_inline_hook.token-hook.id
}
resource okta_auth_server_claim "approle" {
  auth_server_id = okta_auth_server.funauth_authz.id
  name = "funAuthRole"
  value = "appuser.funAuthRole"
  claim_type = "IDENTITY"
  always_include_in_token = true
}
resource "okta_auth_server_claim" "groups" {
  auth_server_id = okta_auth_server.funauth_authz.id
  name = "groups"
  value_type = "GROUPS"
  group_filter_type = "STARTS_WITH"
  value = "FunAuth."
  claim_type = "IDENTITY"
  always_include_in_token = true
}
resource "okta_auth_server_claim" "usergroup" {
  auth_server_id = okta_auth_server.funauth_authz.id
  name = "userGroup"
  value_type = "GROUPS"
  group_filter_type = "CONTAINS"
  value = ".Users"
  claim_type = "IDENTITY"
  always_include_in_token = true
}
#
# NOT YET SUPPORTED BY TERRAFORM PROVIDER
#
# enable/configure the custom OTP authenticator
# resource "okta_authenticator" "emailotp" {
#   name = "Multi-branded Email OTP"
#   key = "custom_otp"
#   settings = jsonencode(
#     {
#       "passCodeLength": "6",
#       "algorithm": "HMacSHA512",
#       "timeIntervalInSeconds": "30",
#       "acceptableAdjacentIntervals": "3"
#       "encoding": "base32"
#     }
#   )
# }
output "client_id" {
  value = "${okta_app_oauth.funauth_oidc.client_id}"
}
output "auth_server_id" {
  value = "${okta_auth_server.funauth_authz.id}"
}
output "issuer" {
  value = "${okta_auth_server.funauth_authz.issuer}"
}
