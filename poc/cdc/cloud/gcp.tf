# env-b: pg-b만 둔다. 앱과 PgBouncer는 env-a에 있고, pg-b는 WireGuard 주소에서만 5432를 연다

resource "google_compute_network" "b" {
  name                    = local.name
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "b" {
  name          = "${local.name}-asia-northeast3"
  network       = google_compute_network.b.id
  ip_cidr_range = "10.20.1.0/24"
}

resource "google_compute_firewall" "wireguard" {
  name          = "${local.name}-wireguard-from-env-a"
  network       = google_compute_network.b.id
  direction     = "INGRESS"
  source_ranges = ["${aws_eip.a.public_ip}/32"]
  target_tags   = ["cdc-poc-env-b"]

  allow {
    protocol = "udp"
    ports    = [tostring(local.wg.b.port)]
  }
}

resource "google_compute_instance" "b" {
  name         = "${local.name}-env-b"
  machine_type = var.env_b_machine_type
  tags         = ["cdc-poc-env-b"]

  boot_disk {
    initialize_params {
      image = "ubuntu-os-cloud/ubuntu-2404-lts-amd64"
      size  = var.disk_gb
      type  = "pd-balanced"
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.b.id
    access_config {
      nat_ip = google_compute_address.b.address
    }
  }

  shielded_instance_config {
    enable_secure_boot = true
  }

  metadata = {
    startup-script = templatefile("${path.module}/templates/env-b.sh.tftpl", {
      wg_private_key = wireguard_asymmetric_key.b.private_key
      wg_peer_key    = wireguard_asymmetric_key.a.public_key
      wg_ip          = local.wg.b.ip
      wg_peer_ip     = local.wg.a.ip
      wg_port        = local.wg.b.port
      peer_endpoint  = "${aws_eip.a.public_ip}:${local.wg.a.port}"
      roles_sql      = file("${path.module}/../init/roles.sql")
      pg_tuning      = var.pg_tuning
    })
  }
}
