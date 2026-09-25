# user_setup

Creating a cluster user authenticated by an x509 client certificate, using
Kubernetes' own CertificateSigningRequest API as the CA.

## How identity works here

Kubernetes has no User object. A client certificate *is* the identity:

| Certificate field | Becomes |
| --- | --- |
| `CN` (Common Name) | the username |
| each `O` (Organization) | a group |

So `/CN=webdeployer/O=devs` authenticates as user `webdeployer` in group `devs`.
Both are RBAC subjects — bind roles to either.

This repo's `website-rolebinding.yaml` binds to the **user** `webdeployer`, so
the worked example below passes no `-g`. Add groups with `-g` if you would rather
bind by group.

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
./create-user-csr.sh webdeployer
```

Options: `-g` adds a group (repeatable), `-e` sets the requested lifetime in
seconds (default 90 days, minimum 600 — the API server rejects less), `-o`
chooses the output directory (default `./<username>`), `-n` writes the manifest
without submitting it.

This produces, in `./webdeployer/`:

| File | |
| --- | --- |
| `webdeployer.key` | the private key, mode 0600 |
| `webdeployer.csr` | the PEM certificate signing request |
| `webdeployer-csr.yaml` | the CertificateSigningRequest manifest |

**The private key never leaves the machine that runs the script.** Only the CSR
is submitted. Generate it wherever the user will keep it, or hand over the key
by some means you trust — not by committing it here.

## 2. Approve it

The `kubernetes.io/kube-apiserver-client` signer is **never auto-approved**;
approval is always a deliberate act by someone with rights over it.

```sh
kubectl get csr webdeployer
kubectl certificate approve webdeployer
```

Check the subject before approving — the requester chose the CN and O, which is
to say they chose the username and groups they are asking to become:

```sh
kubectl get csr webdeployer -o jsonpath='{.spec.request}' | base64 -d | openssl req -noout -subject
```

To refuse instead: `kubectl certificate deny webdeployer`.

## 3. Collect the signed certificate

`make-kubeconfig.sh` does this and step 5 together, and is the easier path:

```sh
./make-kubeconfig.sh webdeployer
```

It reads `.status.certificate` — the certificate the cluster signed, not the
request — writes it to `webdeployer/webdeployer.crt`, and builds `webdeployer/webdeployer.kubeconfig`
around it. It refuses to run on a CSR that is denied, failed, still unapproved,
or approved but not yet signed, rather than producing a kubeconfig with an empty
certificate in it. It also checks the private key on disk matches the
certificate, since a mismatch otherwise surfaces only as an opaque TLS handshake
failure later.

Cluster name, API server URL and CA default to whatever the current kubectl
context points at; `-c`, `-s` and `-a` override them.

By hand, if you prefer:

```sh
kubectl get csr webdeployer -o jsonpath='{.status.certificate}' | base64 -d > webdeployer/webdeployer.crt
openssl x509 -in webdeployer/webdeployer.crt -noout -subject -dates -issuer
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

`website-editor` grants wildcard verbs on wildcard resources within the
namespace — full control of everything in `website`, and nothing outside it.

The RoleBinding's subject is already `webdeployer`, so it applies as-is:

```sh
kubectl apply -f ../cluster_base/website-rolebinding.yaml
```

**If you used a different username, edit the subject to match its CN.** RBAC has
no User object to validate against, so a name that does not match applies
cleanly and grants nothing — the failure shows up as the user being denied
later, not as an error here. Confirm the CN if unsure:

```sh
kubectl get csr webdeployer -o jsonpath='{.spec.request}' | base64 -d \
  | openssl req -noout -subject
```

Step 6 is what catches a mismatch.

### Ad hoc alternatives

Bind to the user directly:

```sh
kubectl create rolebinding webdeployer-website-editor \
  --role=website-editor \
  --user=webdeployer \
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
  --kubeconfig=webdeployer/webdeployer.kubeconfig

kubectl config set-credentials webdeployer \
  --client-certificate=webdeployer/webdeployer.crt \
  --client-key=webdeployer/webdeployer.key \
  --embed-certs=true \
  --kubeconfig=webdeployer/webdeployer.kubeconfig

kubectl config set-context webdeployer@"$CLUSTER" \
  --cluster="$CLUSTER" \
  --user=webdeployer \
  --kubeconfig=webdeployer/webdeployer.kubeconfig

kubectl config use-context webdeployer@"$CLUSTER" --kubeconfig=webdeployer/webdeployer.kubeconfig
```

`--embed-certs=true` inlines the material so the file is self-contained and can
be handed over as one artifact. It therefore **contains the private key** —
the script writes it mode 0600; treat it accordingly.

## 6. Verify

```sh
KC=webdeployer/webdeployer.kubeconfig

kubectl --kubeconfig=$KC auth whoami

# inside the namespace: everything
kubectl --kubeconfig=$KC auth can-i create deployments -n website      # yes
kubectl --kubeconfig=$KC auth can-i delete deployments -n website      # yes
kubectl --kubeconfig=$KC auth can-i get    secrets     -n website      # yes

# outside it: nothing
kubectl --kubeconfig=$KC auth can-i get    pods        -n kube-system  # no
kubectl --kubeconfig=$KC auth can-i get    nodes                       # no

kubectl --kubeconfig=$KC get pods -n website
```

`auth whoami` echoes the username and groups the API server derived from the
certificate — the quickest check that CN and O landed as intended, and the value
the RoleBinding's subject name has to match.

The `can-i` checks prove both halves of what `website-editor` is meant to be:
full control inside `website`, including its Secrets, and nothing at all outside
it. The last two must answer **no** — a `yes` there means the binding is a
ClusterRoleBinding rather than a RoleBinding, or points at a broader role.

If `auth whoami` reports the right user but every `can-i` says no, the
RoleBinding subject name does not match the CN — the failure mode step 4 warns
about.

For the full picture:

```sh
kubectl --kubeconfig=$KC auth can-i --list -n website
```

## Notes for this cluster

- The API server is in the private subnet, so this all runs from the bastion or
  through a tunnel.
- `--certificate-authority` above points at `/etc/kubernetes/pki/ca.crt` on the
  control plane. From elsewhere, take the CA out of an existing kubeconfig:
  `kubectl config view --raw --minify -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' | base64 -d`.
- CSR objects are named after the user, so a second request for the same person
  needs the first deleted: `kubectl delete csr webdeployer`. The script refuses rather
  than clobbering an existing one.
- Renewal is this same process again. There is no rotation mechanism; expiry is
  the only bound on a certificate's life, which is the argument for short ones.
