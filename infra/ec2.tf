# Canonical's published Ubuntu images. The codename is wildcarded so the lookup
# tracks whatever Canonical named the var.ubuntu_version release. Both instances
# are Graviton (t4g), so one arm64 image serves them both.
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd*/ubuntu-*-${var.ubuntu_version}-arm64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  filter {
    name   = "state"
    values = ["available"]
  }
}

# No ingress: nothing was specified for the bastion itself. Add an SSH rule from
# your own address (and a key pair below) before this box is of any use.
resource "aws_instance" "bastion_ec2" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.bastion_instance_type
  key_name               = aws_key_pair.bastion_ec2.key_name
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.bastion_ec2.id]

  # IMDSv2 only, and a hop limit of 1 so pod traffic -- which crosses the
  # Flannel bridge to reach 169.254.169.254 -- cannot read the instance role's
  # credentials. Workloads that legitimately need them run hostNetwork: true.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = var.imds_hop_limit
    instance_metadata_tags      = "enabled"
  }

  root_block_device {
    volume_size           = var.bastion_root_volume_size
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true

    tags = {
      Name = "${var.name}-bastion-root"
    }
  }

  tags = {
    Name = "${var.name}-bastion"
  }
}

resource "aws_instance" "k8s_master" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.k8s_master_instance_type
  key_name               = aws_key_pair.k8s.key_name
  iam_instance_profile   = aws_iam_instance_profile.k8s_master.name
  subnet_id              = aws_subnet.private.id
  vpc_security_group_ids = [aws_security_group.k8s_master.id]

  # IMDSv2 only, and a hop limit of 1 so pod traffic -- which crosses the
  # Flannel bridge to reach 169.254.169.254 -- cannot read the instance role's
  # credentials. Workloads that legitimately need them run hostNetwork: true.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = var.imds_hop_limit
    instance_metadata_tags      = "enabled"
  }

  root_block_device {
    volume_size           = var.k8s_master_root_volume_size
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true

    tags = {
      Name = "${var.name}-k8s-master-root"
    }
  }

  tags = {
    Name = "${var.name}-k8s-master"
  }
}

resource "aws_instance" "k8s_worker" {
  count = var.k8s_worker_count

  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.k8s_worker_instance_type
  key_name               = aws_key_pair.k8s.key_name
  iam_instance_profile   = aws_iam_instance_profile.node.name
  subnet_id              = aws_subnet.private.id
  vpc_security_group_ids = [aws_security_group.k8s_worker.id]

  # IMDSv2 only, and a hop limit of 1 so pod traffic -- which crosses the
  # Flannel bridge to reach 169.254.169.254 -- cannot read the instance role's
  # credentials. Workloads that legitimately need them run hostNetwork: true.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = var.imds_hop_limit
    instance_metadata_tags      = "enabled"
  }

  root_block_device {
    volume_size           = var.k8s_worker_root_volume_size
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true

    tags = {
      Name = "${var.name}-k8s-worker-${count.index + 1}-root"
    }
  }

  tags = {
    Name = "${var.name}-k8s-worker-${count.index + 1}"
  }
}
