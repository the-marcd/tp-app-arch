output "vpc_id" {
  description = "ID of the VPC."
  value       = aws_vpc.main.id
}

output "vpc_cidr_block" {
  description = "CIDR block of the VPC."
  value       = aws_vpc.main.cidr_block
}

output "public_subnet_id" {
  description = "ID of the public subnet."
  value       = aws_subnet.public.id
}

output "private_subnet_id" {
  description = "ID of the private subnet."
  value       = aws_subnet.private.id
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

output "vpc_endpoint_ecr_api_id" {
  description = "ID of the ECR API interface endpoint."
  value       = aws_vpc_endpoint.ecr_api.id
}

output "vpc_endpoint_ecr_dkr_id" {
  description = "ID of the ECR Docker registry interface endpoint."
  value       = aws_vpc_endpoint.ecr_dkr.id
}

output "vpc_endpoint_s3_id" {
  description = "ID of the S3 gateway endpoint."
  value       = aws_vpc_endpoint.s3.id
}

output "vpc_endpoints_security_group_id" {
  description = "ID of the interface endpoints' security group."
  value       = aws_security_group.vpc_endpoints.id
}

output "node_iam_role_arn" {
  description = "ARN of the k8s node IAM role."
  value       = aws_iam_role.node.arn
}

output "node_instance_profile_name" {
  description = "Name of the k8s node instance profile."
  value       = aws_iam_instance_profile.node.name
}
