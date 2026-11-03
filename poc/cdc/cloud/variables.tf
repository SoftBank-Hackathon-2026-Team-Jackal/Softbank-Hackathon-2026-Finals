# 기본값은 5GB 규모 시나리오(scenarios/04_realistic.sh)용. 가벼운 시나리오만 돌릴 때는 t3.small / e2-small, 20GB로 충분하다
variable "env_a_instance_type" {
  type    = string
  default = "t3.large" # 2 vCPU, 8GB. SCP 허용 목록 안
}

variable "env_b_machine_type" {
  type    = string
  default = "e2-standard-2" # 2 vCPU, 8GB
}

variable "disk_gb" {
  type    = number
  default = 60 # 데이터 5GB + 인덱스 + 복사 중 쌓이는 WAL
}

variable "pg_tuning" {
  type = object({ shared_buffers = string, maintenance_work_mem = string, max_wal_size = string })
  default = {
    shared_buffers       = "2GB"
    maintenance_work_mem = "512MB"
    max_wal_size         = "4GB"
  }
}
