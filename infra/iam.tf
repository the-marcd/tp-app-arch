# Instance role for the k8s nodes.

data "aws_iam_policy_document" "node_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "node" {
  name               = "${var.name}-k8s-node"
  description        = "k8s node role: VPC CNI ENI management and ECR pulls"
  assume_role_policy = data.aws_iam_policy_document.node_assume_role.json

  tags = {
    Name = "${var.name}-k8s-node"
  }
}

resource "aws_iam_role_policy_attachment" "vpc_cni" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

# Needed for kubelet/containerd to authenticate to ECR and pull the aws-node
# image through the endpoints in vpc_endpoints.tf. Without it those endpoints
# are reachable but every pull is denied.
resource "aws_iam_role_policy_attachment" "ecr_read_only" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_iam_instance_profile" "node" {
  name = "${var.name}-k8s-node"
  role = aws_iam_role.node.name

  tags = {
    Name = "${var.name}-k8s-node"
  }
}
