# Public key material only, read from .pub files on disk. The private halves are
# never given to Terraform, so they cannot leak into terraform.tfstate; generate
# the pairs out of band (ssh-keygen) and point the *_public_key_path variables
# at the .pub files.
#
# The file is read in a local, not inside the precondition: a missing or
# unreadable path then fails with Terraform's own error naming the path, rather
# than being swallowed by can() and misreported as a malformed key. The
# precondition below checks format only.
#
# trimspace on the path tolerates a stray space from an interactive prompt;
# pathexpand handles a leading ~; trimspace on the content strips the trailing
# newline ssh-keygen writes, which aws_key_pair rejects.

locals {
  bastion_public_key = trimspace(file(pathexpand(trimspace(var.bastion_public_key_path))))
  k8s_public_key     = trimspace(file(pathexpand(trimspace(var.k8s_public_key_path))))

  # An OpenSSH public key is "<type> AAAA<base64>[ comment]". The base64 always
  # begins AAAA because it encodes the length-prefixed type string. Matches
  # ssh-rsa, ssh-ed25519, ecdsa-sha2-*, and the sk-*@openssh.com FIDO types;
  # a private key ("-----BEGIN ...") does not match.
  openssh_public_key_re = "^[a-z0-9@._-]+ AAAA[0-9A-Za-z+/=]+"
}

resource "aws_key_pair" "bastion_ec2" {
  key_name   = "${var.name}-bastion"
  public_key = local.bastion_public_key

  tags = {
    Name = "${var.name}-bastion"
  }

  lifecycle {
    precondition {
      condition     = can(regex(local.openssh_public_key_re, local.bastion_public_key))
      error_message = "The file at bastion_public_key_path (${var.bastion_public_key_path}) is not an OpenSSH public key. Expected \"<type> AAAA... [comment]\" — a private key or an unrelated file will not work."
    }
  }
}

# Shared by every k8s_* node, not just the master.
resource "aws_key_pair" "k8s" {
  key_name   = "${var.name}-k8s"
  public_key = local.k8s_public_key

  tags = {
    Name = "${var.name}-k8s"
  }

  lifecycle {
    precondition {
      condition     = can(regex(local.openssh_public_key_re, local.k8s_public_key))
      error_message = "The file at k8s_public_key_path (${var.k8s_public_key_path}) is not an OpenSSH public key. Expected \"<type> AAAA... [comment]\" — a private key or an unrelated file will not work."
    }
  }
}
