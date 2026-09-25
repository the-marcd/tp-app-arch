# website

A static site: nginx serving an HTML page from a ConfigMap, behind a Network
Load Balancer, over a Let's Encrypt certificate issued by cert-manager, with its
DNS record created by external-dns.

| File | |
| --- | --- |
| `configmap-html.yaml` | the page itself |
| `configmap-nginx.yaml` | the nginx server block; terminates TLS |
| `certificate.yaml` | cert-manager Certificate → `site-tls` Secret |
| `deployment.yaml` | nginx, 2 replicas |
| `service.yaml` | `type: LoadBalancer` with the NLB annotations |

The namespace, Role and RoleBinding live in `../cluster_base/website-*.yaml`.

## Where TLS terminates, and why

**In the pod, not at the load balancer.** An NLB is layer 4; the only
certificate it can serve is one from ACM. A cert-manager certificate lands in a
Kubernetes Secret, which only a pod can read. So the NLB forwards TCP 443
untouched and nginx does the handshake against the mounted Secret.

That shapes the rest: the Service exposes 443 only, the container listens on
443, and the probes use `scheme: HTTPS`.

If you would rather terminate at the edge, that means an ALB with an ACM
certificate and an Ingress — a different set of manifests, and cert-manager
stops being involved.

## Order matters

```
1. namespace                    kubectl apply -f ../cluster_base/website-namespace.yaml
2. configmaps + certificate     the Certificate must be issued before pods can start
3. wait for the Secret          kubectl -n website get secret site-tls
4. deployment                   pods mount that Secret
5. service                      provisions the NLB and the DNS record
```

Applying everything at once works, but pods sit in `ContainerCreating` until the
certificate is issued — the `tls` volume references a Secret that does not exist
yet. That is expected, not a failure:

```sh
kubectl -n website describe certificate site-tls
kubectl -n website get certificate,secret
```

DNS-01 needs a `_acme-challenge` TXT record to propagate, so first issuance takes
a couple of minutes.

## Production certificates

`certificate.yaml` points at `letsencrypt-prod`, so the certificate chains to a
trusted root and browsers do not warn.

Production rate limits are real: roughly 5 failed validations per account,
hostname and hour, and 50 certificates per registered domain per week. A
misconfiguration spends the failure budget rather than simply retrying. If
issuance starts failing, switch to staging while you debug and switch back:

```sh
# certificate.yaml: issuerRef.name -> letsencrypt-staging
kubectl -n website delete secret site-tls     # forces a fresh request
kubectl apply -f certificate.yaml
```

The same two commands move it back to `letsencrypt-prod` afterwards — deleting
the Secret is what makes cert-manager request again rather than reuse what it
already has.

## Editing the page

nginx reads the HTML from a mounted volume. The kubelet syncs ConfigMap changes
into running pods, but with a delay, and nginx caches file handles:

```sh
kubectl apply -f configmap-html.yaml
kubectl -n website rollout restart deploy/site
```

## What this depends on

Everything below has to be in place first. Most of it is already built:

| | |
| --- | --- |
| cert-manager + the ClusterIssuers | `../cluster_base/cert-manager/` |
| AWS Load Balancer Controller | `../cluster_base/aws-load-balancer-controller/` |
| external-dns | `../cluster_base/external-dns/` |
| `tp-app-load-balancer` security group | `../infra/security_groups.tf`, applied |
| `spec.providerID` on every node | done; automatic for new nodes via the common role |

### Two things to know about the security group

The Service names the group by its **`Name` tag**, `tp-app-load-balancer`, not by
id — the annotation accepts either, and the tag survives a rebuild that would
change the id.

Supplying your own group **stops the controller managing worker security group
rules for you**. Traffic still reaches the NodePorts, because the worker group
already admits `30000-32767` from the VPC CIDR and the NLB's interfaces sit
inside the VPC. If you narrow that rule, add an explicit worker ingress rule
from the load balancer group instead.

## Verifying

```sh
kubectl -n website get svc site -o wide          # the NLB hostname
kubectl -n website get certificate site-tls      # READY should be True
dig +short site.tp.darcsaint.net                 # external-dns wrote this
curl -sSv https://site.tp.darcsaint.net          # no -k needed on prod
```

`dig` returning nothing points at external-dns: the delegation itself is in
place, with `darcsaint.net` publishing NS records for `tp.darcsaint.net` that
match the zone's four Route 53 name servers. Check the controller's logs:

```sh
kubectl -n kube-system logs deploy/external-dns
```

### The annotation prefix trap

The hostname annotation is `external-dns.kubernetes.io/hostname`. The older
`external-dns.alpha.kubernetes.io/` prefix is **ignored by default** — current
external-dns ships `--enable-legacy-annotation-prefix` disabled.

It fails silently. No warning, no error, no mention of the Service; external-dns
simply generates no endpoints and logs `All records are already up to date` on
every sync while Route 53 stays empty. Confirm which prefix is in force from the
config dump at the top of its logs:

```sh
kubectl -n kube-system logs deploy/external-dns | head -1 | tr ' ' '\n' | grep -i annotationprefix
```
