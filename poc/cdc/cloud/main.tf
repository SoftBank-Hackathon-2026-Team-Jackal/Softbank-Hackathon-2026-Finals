locals {
  name = "sbh26-cdc-poc"

  # WireGuard 사설망. 앱과 DB 포트는 이 주소에만 연다
  wg = {
    a = { ip = "10.100.0.1", port = 51820 }
    b = { ip = "10.100.0.2", port = 51820 }
  }
}

# ── WireGuard 키 ─────────────────────────────────────────────
# 개인 키가 state와 VM user_data에 들어간다. PoC 한정이며 destroy 후 다시 만들면 새 키가 생긴다.
resource "wireguard_asymmetric_key" "a" {}
resource "wireguard_asymmetric_key" "b" {}

# 두 VM이 서로의 공개 주소를 알아야 하므로 고정 IP를 먼저 만든다
resource "aws_eip" "a" {
  domain = "vpc"
  tags   = { Name = "${local.name}-env-a" }
}

resource "google_compute_address" "b" {
  name = "${local.name}-env-b"
}

# ── 1단계 PoC 파일 묶음 (env-a VM이 S3에서 받아 간다) ─────────────
data "archive_file" "poc" {
  type        = "zip"
  source_dir  = "${path.module}/.."
  output_path = "${path.module}/.build/poc-cdc.zip"
  excludes    = ["cloud", "results", ".build"]
}
