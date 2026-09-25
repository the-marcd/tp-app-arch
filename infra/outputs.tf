output "vpc_id" {
  description = "ID of the VPC."
  value       = aws_vpc.main.id
}

output "vpc_cidr_block" {
  description = "CIDR block of the VPC."
  value       = aws_vpc.main.cidr_block
}

output "public_subnet_id" {
  description = "ID of the public subnet in the first AZ."
  value       = aws_subnet.public.id
}

output "public_subnet_ids" {
  description = "IDs of both public subnets, for load balancer placement."
  value       = [aws_subnet.public.id, aws_subnet.public_b.id]
}

output "private_subnet_id" {
  description = "ID of the private subnet in the first AZ."
  value       = aws_subnet.private.id
}

output "private_subnet_ids" {
  description = "IDs of both private subnets."
  value       = [aws_subnet.private.id, aws_subnet.private_b.id]
}

output "cluster_name" {
  description = "Cluster name used in the kubernetes.io/cluster subnet tag; pass to the controller as --cluster-name."
  value       = local.cluster_name
}

output "internet_gateway_id" {
  description = "ID of the internet gateway attached to the VPC."
  value       = aws_internet_gateway.main.id
}

output "nat_gateway_id" {
  description = "ID of the NAT gateway, or null when enable_nat_gateway is false."
  value       = one(aws_nat_gateway.main[*].id)
}

output "nat_gateway_public_ip" {
  description = "Public IP of the NAT gateway, or null when enable_nat_gateway is false."
  value       = one(aws_eip.nat[*].public_ip)
}

output "public_route_table_id" {
  description = "ID of the public route table."
  value       = aws_route_table.public.id
}

output "private_route_table_id" {
  description = "ID of the private route table."
  value       = aws_route_table.private.id
}

output "bastion_instance_id" {
  description = "ID of the bastion instance."
  value       = aws_instance.bastion_ec2.id
}

output "bastion_public_ip" {
  description = "Public IP of the bastion."
  value       = aws_instance.bastion_ec2.public_ip
}

output "bastion_private_ip" {
  description = "Private IP of the bastion."
  value       = aws_instance.bastion_ec2.private_ip
}

output "bastion_security_group_id" {
  description = "ID of the bastion's security group."
  value       = aws_security_group.bastion_ec2.id
}

output "k8s_master_instance_id" {
  description = "ID of the k8s master instance."
  value       = aws_instance.k8s_master.id
}

output "k8s_master_private_ip" {
  description = "Private IP of the k8s master."
  value       = aws_instance.k8s_master.private_ip
}

output "k8s_master_security_group_id" {
  description = "ID of the k8s master's security group."
  value       = aws_security_group.k8s_master.id
}

output "ami_id" {
  description = "arm64 Ubuntu AMI both instances were launched from."
  value       = data.aws_ami.ubuntu.id
}

output "bastion_key_pair_name" {
  description = "Name of the bastion's EC2 key pair."
  value       = aws_key_pair.bastion_ec2.key_name
}

output "k8s_key_pair_name" {
  description = "Name of the EC2 key pair shared by the k8s_* nodes."
  value       = aws_key_pair.k8s.key_name
}

output "k8s_worker_instance_ids" {
  description = "IDs of the k8s worker instances."
  value       = aws_instance.k8s_worker[*].id
}

output "k8s_worker_private_ips" {
  description = "Private IPs of the k8s worker instances."
  value       = aws_instance.k8s_worker[*].private_ip
}

output "k8s_worker_security_group_id" {
  description = "ID of the k8s workers' security group."
  value       = aws_security_group.k8s_worker.id
}

output "vpc_endpoint_s3_id" {
  description = "ID of the S3 gateway endpoint."
  value       = aws_vpc_endpoint.s3.id
}


output "node_iam_role_arn" {
  description = "ARN of the k8s worker node IAM role."
  value       = aws_iam_role.node.arn
}

output "node_instance_profile_name" {
  description = "Name of the k8s worker node instance profile."
  value       = aws_iam_instance_profile.node.name
}

output "k8s_master_iam_role_arn" {
  description = "ARN of the k8s control plane IAM role."
  value       = aws_iam_role.k8s_master.arn
}

output "k8s_master_instance_profile_name" {
  description = "Name of the k8s control plane instance profile."
  value       = aws_iam_instance_profile.k8s_master.name
}

output "s3_bucket_name" {
  description = "Name of the application S3 bucket."
  value       = aws_s3_bucket.main.id
}

output "s3_bucket_arn" {
  description = "ARN of the application S3 bucket."
  value       = aws_s3_bucket.main.arn
}

output "s3_access_policy_arn" {
  description = "ARN of the read/write S3 policy attached to the control plane role."
  value       = aws_iam_policy.s3_access.arn
}

output "s3_read_policy_arn" {
  description = "ARN of the read-only S3 policy attached to the worker node role."
  value       = aws_iam_policy.s3_read.arn
}

output "aws_load_balancer_controller_policy_arn" {
  description = "ARN of the vendored AWS Load Balancer Controller policy."
  value       = aws_iam_policy.aws_load_balancer_controller.arn
}

output "oidc_bucket_name" {
  description = "Name of the public OIDC discovery bucket."
  value       = aws_s3_bucket.oidc.id
}

output "oidc_bucket_arn" {
  description = "ARN of the public OIDC discovery bucket."
  value       = aws_s3_bucket.oidc.arn
}

output "oidc_issuer_url" {
  description = "Issuer URL for the OIDC bucket; use as kube-apiserver --service-account-issuer and as the IAM OIDC provider URL."
  value       = local.oidc_issuer_url
}

output "cluster_oidc_provider_arn" {
  description = "ARN of the cluster's IAM OIDC provider, or null when enable_oidc_provider is false."
  value       = one(aws_iam_openid_connect_provider.cluster[*].arn)
}

output "aws_load_balancer_controller_role_arn" {
  description = "ARN of the IRSA role for the AWS Load Balancer Controller service account; set as its eks.amazonaws.com/role-arn annotation or AWS_ROLE_ARN."
  value       = one(aws_iam_role.aws_load_balancer_controller[*].arn)
}

output "dns_zone_id" {
  description = "ID of the public hosted zone."
  value       = aws_route53_zone.tp.zone_id
}

output "dns_zone_arn" {
  description = "ARN of the public hosted zone."
  value       = aws_route53_zone.tp.arn
}

output "dns_zone_name_servers" {
  description = "Name servers for the zone; create these as an NS record set in the parent zone to delegate to it."
  value       = aws_route53_zone.tp.name_servers
}

output "external_dns_role_arn" {
  description = "ARN of the IRSA role for the external-dns service account."
  value       = one(aws_iam_role.external_dns[*].arn)
}

output "cert_manager_role_arn" {
  description = "ARN of the IRSA role for the cert-manager service account; set as its eks.amazonaws.com/role-arn annotation."
  value       = one(aws_iam_role.cert_manager[*].arn)
}

output "load_balancer_security_group_id" {
  description = "ID of the load balancer security group; pass to Ingresses via the alb.ingress.kubernetes.io/security-groups annotation."
  value       = aws_security_group.load_balancer.id
}
