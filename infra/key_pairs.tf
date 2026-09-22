# Public key material only. The private halves are never given to Terraform, so
# they cannot leak into terraform.tfstate; generate the pairs out of band
# (ssh-keygen) and pass the .pub contents in.

resource "aws_key_pair" "bastion_ec2" {
  key_name   = "${var.name}-bastion"
  public_key = var.bastion_public_key

  tags = {
    Name = "${var.name}-bastion"
  }
}

# Shared by every k8s_* node, not just the master.
resource "aws_key_pair" "k8s" {
  key_name   = "${var.name}-k8s"
  public_key = var.k8s_public_key

  tags = {
    Name = "${var.name}-k8s"
  }
}
