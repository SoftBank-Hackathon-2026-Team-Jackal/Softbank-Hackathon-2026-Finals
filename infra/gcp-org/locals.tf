locals {
  org_id = "994714599350"
  region = "asia-northeast3"

  # 폴더 이름 = 프로젝트 표시 이름. 프로젝트 ID는 전역에서 고유해야 하므로 접두어를 붙입니다.
  workloads = {
    prod = {
      apis = [
        "billingbudgets.googleapis.com", # 할당량 프로젝트로 씀
        "cloudbilling.googleapis.com",
        "cloudresourcemanager.googleapis.com",
        "compute.googleapis.com",
        "iam.googleapis.com",
        "iamcredentials.googleapis.com",
        "logging.googleapis.com",
        "monitoring.googleapis.com",
        "serviceusage.googleapis.com",
        "sts.googleapis.com",
      ]
    }
    sandbox = {
      apis = [
        "cloudresourcemanager.googleapis.com",
        "compute.googleapis.com",
        "iam.googleapis.com",
        "logging.googleapis.com",
        "monitoring.googleapis.com",
        "serviceusage.googleapis.com",
      ]
    }
  }

  quota_project = "sbh26-prod"

  project_apis = merge([
    for env, w in local.workloads : { for api in w.apis : "${env}/${api}" => { env = env, api = api } }
  ]...)

  team_bindings = merge([
    for env in keys(local.workloads) : { for m in var.team_members : "${env}/${m}" => { env = env, member = m } }
  ]...)
}
