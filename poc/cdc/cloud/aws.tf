# env-a: pg-a, PgBouncer, 부하 생성기, toolbox

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical
  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }
}

resource "aws_vpc" "a" {
  cidr_block           = "10.10.0.0/16"
  enable_dns_hostnames = true
  tags                 = { Name = local.name }
}

resource "aws_internet_gateway" "a" {
  vpc_id = aws_vpc.a.id
  tags   = { Name = local.name }
}

resource "aws_subnet" "a" {
  vpc_id            = aws_vpc.a.id
  cidr_block        = "10.10.1.0/24"
  availability_zone = "ap-northeast-2a"
  tags              = { Name = "${local.name}-public" }
}

resource "aws_route_table" "a" {
  vpc_id = aws_vpc.a.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.a.id
  }
  tags = { Name = local.name }
}

resource "aws_route_table_association" "a" {
  subnet_id      = aws_subnet.a.id
  route_table_id = aws_route_table.a.id
}

# 들어오는 것은 env-b의 WireGuard뿐. SSH는 열지 않고 SSM으로 접속한다
resource "aws_security_group" "a" {
  name   = "${local.name}-env-a"
  vpc_id = aws_vpc.a.id

  ingress {
    description = "WireGuard from env-b"
    protocol    = "udp"
    from_port   = local.wg.a.port
    to_port     = local.wg.a.port
    cidr_blocks = ["${google_compute_address.b.address}/32"]
  }

  egress {
    protocol    = "-1"
    from_port   = 0
    to_port     = 0
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_s3_bucket" "bundle" {
  bucket        = "${local.name}-bundle-${data.aws_caller_identity.current.account_id}"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "bundle" {
  bucket                  = aws_s3_bucket.bundle.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_object" "bundle" {
  bucket = aws_s3_bucket.bundle.id
  key    = "poc-cdc.zip"
  source = data.archive_file.poc.output_path
  etag   = data.archive_file.poc.output_md5
}

data "aws_caller_identity" "current" {}

resource "aws_iam_role" "a" {
  name = "${local.name}-env-a"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = "ec2.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.a.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "bundle" {
  role = aws_iam_role.a.id
  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Action = "s3:GetObject", Resource = "${aws_s3_bucket.bundle.arn}/*" }]
  })
}

resource "aws_iam_instance_profile" "a" {
  name = "${local.name}-env-a"
  role = aws_iam_role.a.name
}

resource "aws_instance" "a" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = "t3.small"
  subnet_id              = aws_subnet.a.id
  vpc_security_group_ids = [aws_security_group.a.id]
  iam_instance_profile   = aws_iam_instance_profile.a.name

  metadata_options {
    http_tokens = "required"
  }

  root_block_device {
    volume_size = 20
    volume_type = "gp3"
    encrypted   = true
  }

  user_data_replace_on_change = true
  user_data = templatefile("${path.module}/templates/env-a.sh.tftpl", {
    wg_private_key = wireguard_asymmetric_key.a.private_key
    wg_peer_key    = wireguard_asymmetric_key.b.public_key
    wg_ip          = local.wg.a.ip
    wg_peer_ip     = local.wg.b.ip
    wg_port        = local.wg.a.port
    peer_endpoint  = "${google_compute_address.b.address}:${local.wg.b.port}"
    bundle_url     = "s3://${aws_s3_bucket.bundle.id}/${aws_s3_object.bundle.key}"
  })

  tags = { Name = "${local.name}-env-a" }
}

resource "aws_eip_association" "a" {
  instance_id   = aws_instance.a.id
  allocation_id = aws_eip.a.id
}
