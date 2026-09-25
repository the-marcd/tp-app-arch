# user_setup

Creating a cluster user authenticated by an x509 client certificate, using
Kubernetes' own CertificateSigningRequest API as the CA.

## How identity works here

Kubernetes has no User object. A client certificate *is* the identity:

| Certificate field | Becomes |
| --- | --- |
| `CN` (Common Name) | the username |
| each `O` (Organization) | a group |

So `/CN=alice/O=devs` authenticates as user `alice` in group `devs`. Both are
RBAC subjects — bind roles to either.

Two consequences worth internalising:

- **There is nothing to delete.** Revoking a user means removing their
  RoleBindings, because Kubernetes does not support certificate revocation
  lists. A signed certificate authenticates until it expires, whatever RBAC
  says. Keep lifetimes short.
- **`spec.username` and `spec.groups` on the CertificateSigningRequest object
  are not the identity.** They record who *submitted* the request. The identity
  comes only from the CSR subject.

## The sequence

Steps 1 and 3 onwards are yours to run. **Step 2 is a gate you cannot script past**:
the `kubernetes.io/kube-apiserver-client` signer is never auto-approved, so
nothing is issued until a human with rights over CSRs approves the request.

```
1. create-user-csr.sh            key + CSR + CertificateSigningRequest object
        |
2. kubectl certificate approve   <-- manual gate; no certificate exists before this
        |
3. make-kubeconfig.sh            collects .status.certificate, writes the kubeconfig
   (sections 3 and 5)
        |
4. apply the RoleBinding         authorisation
        |
5. verify
```

Two scripts, one manual step between them. Sections 3 and 5 below are both
covered by `make-kubeconfig.sh`; each also documents the equivalent kubectl
commands if you would rather do it by hand.

The RoleBinding in step 4 can technically be applied at any point — RBAC does
not check that its subject exists. But it does nothing until the certificate
from step 3 exists, and if the name in it does not match that certificate's CN
it will keep doing nothing, with no error to say so. Applying it after step 3,
against a CN you have just read back, is what makes the mismatch visible.

## 1. Generate the key and submit the request

```sh
./create-user-csr.sh alice -g devs
```

Options: `-g` adds a group (repeatable), `-e` sets the requested lifetime in
seconds (default 90 days, minimum 600 — the API server rejects less), `-o`
chooses the output directory (default `./<username>`), `-n` writes the manifest
without submitting it.

This produces, in `./alice/`:

| File | |
| --- | --- |
| `alice.key` | the private key, mode 0600 |
| `alice.csr` | the PEM certificate signing request |
| `alice-csr.yaml` | the CertificateSigningRequest manifest |

**The private key never leaves the machine that runs the script.** Only the CSR
is submitted. Generate it wherever the user will keep it, or hand over the key
by some means you trust — not by committing it here.

## 2. Approve it

The `kubernetes.io/kube-apiserver-client` signer is **never auto-approved**;
approval is always a deliberate act by someone with rights over it.

```sh
kubectl get csr alice
kubectl certificate approve alice
```

Check the subject before approving — the requester chose the CN and O, which is
to say they chose the username and groups they are asking to become:

```sh
kubectl get csr alice -o jsonpath='{.spec.request}' | base64 -d | openssl req -noout -subject
```

To refuse instead: `kubectl certificate deny alice`.

## 3. Collect the signed certificate

`make-kubeconfig.sh` does this and step 5 together, and is the easier path:

```sh
./make-kubeconfig.sh alice
```

It reads `.status.certificate` — the certificate the cluster signed, not the
request — writes it to `alice/alice.crt`, and builds `alice/alice.kubeconfig`
around it. It refuses to run on a CSR that is denied, failed, still unapproved,
or approved but not yet signed, rather than producing a kubeconfig with an empty
certificate in it. It also checks the private key on disk matches the
certificate, since a mismatch otherwise surfaces only as an opaque TLS handshake
failure later.

Cluster name, API server URL and CA default to whatever the current kubectl
context points at; `-c`, `-s` and `-a` override them.

By hand, if you prefer:

```sh
kubectl get csr alice -o jsonpath='{.status.certificate}' | base64 -d > alice/alice.crt
openssl x509 -in alice/alice.crt -noout -subject -dates -issuer
```

If `.status.certificate` is empty, the signing controller has not issued it yet —
give it a moment and retry. If it stays empty, the CSR was approved but the
signer name is one nothing in the cluster signs.

## 4. Grant access

Only now, with a certificate in hand. The certificate authenticates but
authorises nothing — until a binding exists, every request is denied.

This repo ships a namespace, a Role and a RoleBinding for the `website`
namespace:

```sh
kubectl apply -f ../cluster_base/website-namespace.yaml
kubectl apply -f ../cluster_base/website-role.yaml
```

`website-editor` grants create/read/update on deployments, configmaps and
services, and full CRUD on pods.

**Edit the subject name in the RoleBinding before applying it.** It ships as
`CHANGE-ME-username` and must equal the CN of the certificate from step 3:

```sh
kubectl get csr alice -o jsonpath='{.spec.request}' | base64 -d \
  | openssl req -noout -subject          # confirm the CN
$EDITOR ../cluster_base/website-rolebinding.yaml
kubectl apply -f ../cluster_base/website-rolebinding.yaml
```

RBAC has no User object to validate against, so a wrong name applies cleanly and
grants nothing — the failure shows up as the user being denied later, not as an
error here. Step 6 is what catches it.

### Ad hoc alternatives

Bind to the user directly:

```sh
kubectl create rolebinding alice-website-editor \
  --role=website-editor \
  --user=alice \
  --namespace=website
```

Or to a group, which scales better — new users join by holding the right `O`,
with no binding changes:

```sh
kubectl create rolebinding devs-website-editor \
  --role=website-editor \
  --group=devs \
  --namespace=website
```

Cluster-wide, use `kubectl create clusterrolebinding` with `--clusterrole`.

## 5. Build a kubeconfig

Already done if you ran `make-kubeconfig.sh` in step 3. The manual equivalent:

```sh
CLUSTER=tp-app
SERVER=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')

kubectl config set-cluster "$CLUSTER" \
  --server="$SERVER" \
  --certificate-authority=/etc/kubernetes/pki/ca.crt \
  --embed-certs=true \
  --kubeconfig=alice/alice.kubeconfig

kubectl config set-credentials alice \
  --client-certificate=alice/alice.crt \
  --client-key=alice/alice.key \
  --embed-certs=true \
  --kubeconfig=alice/alice.kubeconfig

kubectl config set-context alice@"$CLUSTER" \
  --cluster="$CLUSTER" \
  --user=alice \
  --kubeconfig=alice/alice.kubeconfig

kubectl config use-context alice@"$CLUSTER" --kubeconfig=alice/alice.kubeconfig
```

`--embed-certs=true` inlines the material so the file is self-contained and can
be handed over as one artifact. It therefore **contains the private key** —
the script writes it mode 0600; treat it accordingly.

## 6. Verify

```sh
KC=alice/alice.kubeconfig

kubectl --kubeconfig=$KC auth whoami
kubectl --kubeconfig=$KC auth can-i create pods        -n website   # yes
kubectl --kubeconfig=$KC auth can-i delete pods        -n website   # yes
kubectl --kubeconfig=$KC auth can-i delete deployments -n website   # no
kubectl --kubeconfig=$KC get pods -n website
```

`auth whoami` echoes the username and groups the API server derived from the
certificate — the quickest check that CN and O landed as intended, and the value
the RoleBinding's subject name has to match.

The three `can-i` checks exercise the shape of `website-editor` specifically:
pods are full CRUD, deployments stop short of deletion. If `auth whoami` reports
the right user but every `can-i` says no, the RoleBinding subject name does not
match the CN — the failure mode step 4 warns about.

## Notes for this cluster

- The API server is in the private subnet, so this all runs from the bastion or
  through a tunnel.
- `--certificate-authority` above points at `/etc/kubernetes/pki/ca.crt` on the
  control plane. From elsewhere, take the CA out of an existing kubeconfig:
  `kubectl config view --raw --minify -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' | base64 -d`.
- CSR objects are named after the user, so a second request for the same person
  needs the first deleted: `kubectl delete csr alice`. The script refuses rather
  than clobbering an existing one.
- Renewal is this same process again. There is no rotation mechanism; expiry is
  the only bound on a certificate's life, which is the argument for short ones.
