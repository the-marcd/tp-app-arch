# Security groups and their rules.
#
# Rules are standalone resources rather than inline `ingress`/`egress` blocks:
# the master and worker groups reference each other, which Terraform cannot
# resolve when the rules live inside the group resources.
#
# Port assignments follow the port table supplied by the user. Pod-network (CNI)
# ports are NOT included -- that table lists none -- see README.

resource "aws_security_group" "bastion_ec2" {
  name        = "${var.name}-bastion"
  description = "Bastion: egress only, no inbound access"
  vpc_id      = aws_vpc.main.id

  tags = {
    Name = "${var.name}-bastion"
  }
}

resource "aws_security_group" "k8s_master" {
  name        = "${var.name}-k8s-master"
  description = "k8s control plane"
  vpc_id      = aws_vpc.main.id

  tags = {
    Name = "${var.name}-k8s-master"
  }
}

resource "aws_security_group" "k8s_worker" {
  name        = "${var.name}-k8s-worker"
  description = "k8s workers"
  vpc_id      = aws_vpc.main.id

  tags = {
    Name = "${var.name}-k8s-worker"
  }
}

# ---------------------------------------------------------------------------
# Egress: unrestricted for every group.
# ---------------------------------------------------------------------------

resource "aws_vpc_security_group_egress_rule" "bastion_all" {
  security_group_id = aws_security_group.bastion_ec2.id
  description       = "All outbound"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_egress_rule" "k8s_master_all" {
  security_group_id = aws_security_group.k8s_master.id
  description       = "All outbound"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_egress_rule" "k8s_worker_all" {
  security_group_id = aws_security_group.k8s_worker.id
  description       = "All outbound"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

# ---------------------------------------------------------------------------
# Administrative SSH, bastion -> nodes.
# ---------------------------------------------------------------------------

resource "aws_vpc_security_group_ingress_rule" "k8s_master_ssh" {
  security_group_id            = aws_security_group.k8s_master.id
  description                  = "SSH from the bastion"
  from_port                    = 22
  to_port                      = 22
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.bastion_ec2.id
}

resource "aws_vpc_security_group_ingress_rule" "k8s_worker_ssh" {
  security_group_id            = aws_security_group.k8s_worker.id
  description                  = "SSH from the bastion"
  from_port                    = 22
  to_port                      = 22
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.bastion_ec2.id
}

# ---------------------------------------------------------------------------
# Control plane inbound.
# ---------------------------------------------------------------------------

resource "aws_vpc_security_group_ingress_rule" "k8s_api_from_workers" {
  security_group_id            = aws_security_group.k8s_master.id
  description                  = "kube-apiserver from workers"
  from_port                    = 6443
  to_port                      = 6443
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.k8s_worker.id
}

resource "aws_vpc_security_group_ingress_rule" "k8s_api_from_bastion" {
  security_group_id            = aws_security_group.k8s_master.id
  description                  = "kube-apiserver from the bastion (kubectl)"
  from_port                    = 6443
  to_port                      = 6443
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.bastion_ec2.id
}

resource "aws_vpc_security_group_ingress_rule" "k8s_etcd" {
  security_group_id            = aws_security_group.k8s_master.id
  description                  = "etcd client and peer API, control plane only"
  from_port                    = 2379
  to_port                      = 2380
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.k8s_master.id
}

resource "aws_vpc_security_group_ingress_rule" "k8s_master_kubelet_self" {
  security_group_id            = aws_security_group.k8s_master.id
  description                  = "kubelet API from the control plane"
  from_port                    = 10250
  to_port                      = 10250
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.k8s_master.id
}

resource "aws_vpc_security_group_ingress_rule" "k8s_controller_manager" {
  security_group_id            = aws_security_group.k8s_master.id
  description                  = "kube-controller-manager, control plane only"
  from_port                    = 10257
  to_port                      = 10257
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.k8s_master.id
}

resource "aws_vpc_security_group_ingress_rule" "k8s_scheduler" {
  security_group_id            = aws_security_group.k8s_master.id
  description                  = "kube-scheduler, control plane only"
  from_port                    = 10259
  to_port                      = 10259
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.k8s_master.id
}

# ---------------------------------------------------------------------------
# Worker inbound.
# ---------------------------------------------------------------------------

resource "aws_vpc_security_group_ingress_rule" "k8s_worker_kubelet_from_master" {
  security_group_id            = aws_security_group.k8s_worker.id
  description                  = "kubelet API from the control plane"
  from_port                    = 10250
  to_port                      = 10250
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.k8s_master.id
}

resource "aws_vpc_security_group_ingress_rule" "k8s_worker_kube_proxy" {
  security_group_id            = aws_security_group.k8s_worker.id
  description                  = "kube-proxy health endpoint, node itself"
  from_port                    = 10256
  to_port                      = 10256
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.k8s_worker.id
}

resource "aws_vpc_security_group_ingress_rule" "k8s_worker_nodeport_tcp" {
  security_group_id = aws_security_group.k8s_worker.id
  description       = "NodePort services (TCP), from inside the VPC"
  from_port         = 30000
  to_port           = 32767
  ip_protocol       = "tcp"
  cidr_ipv4         = aws_vpc.main.cidr_block
}

resource "aws_vpc_security_group_ingress_rule" "k8s_worker_nodeport_udp" {
  security_group_id = aws_security_group.k8s_worker.id
  description       = "NodePort services (UDP), from inside the VPC"
  from_port         = 30000
  to_port           = 32767
  ip_protocol       = "udp"
  cidr_ipv4         = aws_vpc.main.cidr_block
}

# ---------------------------------------------------------------------------
# Pod network (AWS VPC CNI).
#
# The CNI assigns pods real VPC addresses on secondary ENIs, and those ENIs
# inherit their node's security group. Pod traffic is not encapsulated, so it
# is evaluated against these groups on whatever port the workload uses -- which
# is not knowable in advance. Hence all protocols, all ports, between the node
# groups (and each group to itself, for the multi-ENI and cross-node cases).
#
# These rules subsume the narrower master<->worker rules above; those are kept
# because they document which component needs which port.
# ---------------------------------------------------------------------------

resource "aws_vpc_security_group_ingress_rule" "pods_master_from_workers" {
  security_group_id            = aws_security_group.k8s_master.id
  description                  = "Pod traffic from workers (VPC CNI)"
  ip_protocol                  = "-1"
  referenced_security_group_id = aws_security_group.k8s_worker.id
}

resource "aws_vpc_security_group_ingress_rule" "pods_master_from_master" {
  security_group_id            = aws_security_group.k8s_master.id
  description                  = "Pod traffic within the control plane (VPC CNI)"
  ip_protocol                  = "-1"
  referenced_security_group_id = aws_security_group.k8s_master.id
}

resource "aws_vpc_security_group_ingress_rule" "pods_workers_from_master" {
  security_group_id            = aws_security_group.k8s_worker.id
  description                  = "Pod traffic from the control plane (VPC CNI)"
  ip_protocol                  = "-1"
  referenced_security_group_id = aws_security_group.k8s_master.id
}

resource "aws_vpc_security_group_ingress_rule" "pods_workers_from_workers" {
  security_group_id            = aws_security_group.k8s_worker.id
  description                  = "Pod traffic between workers (VPC CNI)"
  ip_protocol                  = "-1"
  referenced_security_group_id = aws_security_group.k8s_worker.id
}
