# Security groups and their rules.
#
# Rules are standalone resources rather than inline `ingress`/`egress` blocks:
# the master and worker groups reference each other, which Terraform cannot
# resolve when the rules live inside the group resources.
#
# Cluster port assignments follow the port table supplied by the user. The pod
# network is Flannel with the default VXLAN backend, which adds UDP 8472 between
# nodes -- see the Flannel section at the bottom of this file.

resource "aws_security_group" "bastion_ec2" {
  name        = "${var.name}-bastion"
  description = "Bastion: SSH from approved addresses"
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

# Attached to load balancers the AWS Load Balancer Controller provisions, via
# the alb.ingress.kubernetes.io/security-groups annotation. Without that
# annotation the controller creates and manages its own group instead and this
# one goes unused.
resource "aws_security_group" "load_balancer" {
  name        = "${var.name}-load-balancer"
  description = "Load balancers fronting the cluster"
  vpc_id      = aws_vpc.main.id

  tags = {
    Name = "${var.name}-load-balancer"
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
# Load balancer.
#
# HTTPS from anywhere, plus anything from the workers. Note there is no port 80
# rule: a listener redirecting HTTP to HTTPS would need one added.
# ---------------------------------------------------------------------------

resource "aws_vpc_security_group_ingress_rule" "load_balancer_https" {
  security_group_id = aws_security_group.load_balancer.id
  description       = "HTTPS from anywhere"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_ingress_rule" "load_balancer_from_workers" {
  security_group_id            = aws_security_group.load_balancer.id
  description                  = "All traffic from the worker nodes"
  ip_protocol                  = "-1"
  referenced_security_group_id = aws_security_group.k8s_worker.id
}

# The direction load balancer traffic actually travels: the ALB opens
# connections to the NodePorts. A security group with no egress rules blocks all
# outbound, so without this the load balancer cannot reach its targets at all.
resource "aws_vpc_security_group_egress_rule" "load_balancer_to_workers" {
  security_group_id            = aws_security_group.load_balancer.id
  description                  = "All traffic to the worker nodes"
  ip_protocol                  = "-1"
  referenced_security_group_id = aws_security_group.k8s_worker.id
}

# Egress from the workers to the load balancer group. Note the worker group
# already allows all egress to 0.0.0.0/0, so this grants nothing new -- and the
# direction that actually carries load balancer traffic is the opposite one:
# the load balancer opens connections TO the NodePorts, which the existing
# 30000-32767-from-VPC-CIDR ingress rule covers.
resource "aws_vpc_security_group_egress_rule" "k8s_worker_to_load_balancer" {
  security_group_id            = aws_security_group.k8s_worker.id
  description                  = "All traffic to the load balancer group"
  ip_protocol                  = "-1"
  referenced_security_group_id = aws_security_group.load_balancer.id
}

# ---------------------------------------------------------------------------
# Administrative access: operator -> bastion on SSH, then bastion -> nodes on
# anything.
#
# The bastion's own ingress stays narrow: TCP 22 from var.bastion_ssh_cidrs
# only. What widened is what the bastion may reach once you are on it -- the two
# node groups now admit all protocols and ports from the bastion's security
# group, replacing the port-22-only rules that were here.
#
# This is a deliberate trade: the bastion becomes a full jump host (kubectl to
# 6443, NodePorts, kubelet, anything else) at the cost of making it the single
# point that must stay locked down. Its ingress CIDR list is the only thing
# keeping this closed.
# ---------------------------------------------------------------------------

resource "aws_vpc_security_group_ingress_rule" "bastion_ssh" {
  for_each = toset(var.bastion_ssh_cidrs)

  security_group_id = aws_security_group.bastion_ec2.id
  description       = "SSH from ${each.value}"
  from_port         = 22
  to_port           = 22
  ip_protocol       = "tcp"
  cidr_ipv4         = each.value
}

# ip_protocol "-1" means every protocol; from_port/to_port must be omitted.
resource "aws_vpc_security_group_ingress_rule" "k8s_master_from_bastion" {
  security_group_id            = aws_security_group.k8s_master.id
  description                  = "All traffic from the bastion"
  ip_protocol                  = "-1"
  referenced_security_group_id = aws_security_group.bastion_ec2.id
}

resource "aws_vpc_security_group_ingress_rule" "k8s_worker_from_bastion" {
  security_group_id            = aws_security_group.k8s_worker.id
  description                  = "All traffic from the bastion"
  ip_protocol                  = "-1"
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
# Pod network: Flannel, VXLAN backend.
#
# Flannel encapsulates pod traffic in VXLAN, so the packets that actually cross
# the wire are node-IP to node-IP on UDP 8472. The pod addresses live inside the
# tunnel and are never evaluated by a security group -- which is why this needs
# one UDP port rather than the all-protocol node-to-node allow the AWS VPC CNI
# would have required.
#
# Every node must reach every other node, hence both directions plus each group
# to itself.
# ---------------------------------------------------------------------------

resource "aws_vpc_security_group_ingress_rule" "flannel_master_from_workers" {
  security_group_id            = aws_security_group.k8s_master.id
  description                  = "Flannel VXLAN from workers"
  from_port                    = 8472
  to_port                      = 8472
  ip_protocol                  = "udp"
  referenced_security_group_id = aws_security_group.k8s_worker.id
}

resource "aws_vpc_security_group_ingress_rule" "flannel_master_from_master" {
  security_group_id            = aws_security_group.k8s_master.id
  description                  = "Flannel VXLAN within the control plane"
  from_port                    = 8472
  to_port                      = 8472
  ip_protocol                  = "udp"
  referenced_security_group_id = aws_security_group.k8s_master.id
}

resource "aws_vpc_security_group_ingress_rule" "flannel_workers_from_master" {
  security_group_id            = aws_security_group.k8s_worker.id
  description                  = "Flannel VXLAN from the control plane"
  from_port                    = 8472
  to_port                      = 8472
  ip_protocol                  = "udp"
  referenced_security_group_id = aws_security_group.k8s_master.id
}

resource "aws_vpc_security_group_ingress_rule" "flannel_workers_from_workers" {
  security_group_id            = aws_security_group.k8s_worker.id
  description                  = "Flannel VXLAN between workers"
  from_port                    = 8472
  to_port                      = 8472
  ip_protocol                  = "udp"
  referenced_security_group_id = aws_security_group.k8s_worker.id
}
