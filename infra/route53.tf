# Public hosted zone for the cluster's records.
#
# tp.darcsaint.net is a subdomain, so this zone only resolves once the parent
# darcsaint.net zone delegates to it with an NS record set matching the
# dns_zone_name_servers output. Creating the zone here does not create that
# delegation -- see README.

resource "aws_route53_zone" "tp" {
  name    = var.dns_zone_name
  comment = "Managed by Terraform; records written by external-dns in the ${local.cluster_name} cluster"

  tags = {
    Name = var.dns_zone_name
  }
}
