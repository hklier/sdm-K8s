# Manage the running SDM lab through GitHub and Argo CD

Use the empty public repository [hklier/sdm-K8s](https://github.com/hklier/sdm-K8s) to describe the SDM instance already running in your Kubernetes lab. Store manifests and the image build recipe in Git. Keep the container image in the existing lab registry initially. Argo CD reads Git and reconciles the Kubernetes resources that reference that image.

This procedure adopts the existing instance. It does not reinstall SDM, allocate another pod IP, initialize a new database or replace the current credentials. Execute the commands yourself in the numbered order. None of the Git pushes, cluster changes or Argo CD sync operations below were performed while preparing the guide.

## Current deployment

Read-only inspection on 6 November 2026 found:

| Setting | Current value |
|---|---|
| Git repository | `https://github.com/hklier/sdm-K8s.git`, public, empty, default branch `main` |
| Kubernetes administration host | `192.168.3.5`, user `hkl` |
| Argo CD | Version `3.4.5`, namespace `argocd`, browser endpoint `https://192.168.2.243/` |
| SDM namespace and workload | `sdm-lab`, StatefulSet `sdm`, pod `sdm-0`, one ready replica |
| Worker and pod address | `k8s-worker1`, `10.244.194.67` |
| Browser endpoint | `https://192.168.0.240:8443/` |
| Image | `192.168.2.240:5000/sdm-lab@sha256:78edaf080feec31cfe163e57cbe768b96f6250915897b74ac77ce0d0f277aead` |
| Storage | PVC `sdm-data`, PV `sdm-lab-local`, directory `/var/lib/sdm-lab` on worker1 |
| Credentials | Existing Kubernetes Secret `sdm-setup` |
| Update strategy | `OnDelete` |

The exporter reads the live deployment again when you run it, so the committed configuration reflects its state at that time.

## What belongs in GitHub

Commit Kubernetes manifests, Argo CD configuration and the three small image build files. Do not commit an image archive, the Oracle installer, SDM databases, certificates, setup properties or any GitHub token. The repository is public. The image stays in the lab registry; optional step 12 explains how to put it in a private GitHub Container Registry package associated with this repository. [GitHub documents the distinction between a repository and its container package](https://docs.github.com/en/packages/working-with-a-github-packages-registry/working-with-the-container-registry).

Two image characteristics affect ongoing management:

- `OnDelete` means syncing a changed pod template does not automatically restart the existing pod.
- The image persists the installed SDM application under `/opt/AcmePacket` alongside its state. A new image digest alone does **not** upgrade the SDM binaries already on that volume. SDM version upgrades require the vendor upgrade procedure and a recoverable database backup. A Git revert does not roll back the SDM database or installed files.

## 1 Copy the guide bundle to the administration host

Extract the supplied ZIP on your Windows workstation. Open PowerShell in the extracted directory, which contains `github-argocd-guide`.

```powershell
$sdmKey = 'C:\Users\Heino Klier\Documents\Codex HK\ssh\hkl.priv.ppk'
$puttyTools = 'C:\Program Files\PuTTY'

& "$puttyTools\pscp.exe" -r -i "$sdmKey" `
  -hostkey 'SHA256:mJz76idu6OVdaDsWdEnO5u3PjoyGpaliUR2uQ/o55Qw' `
  '.\github-argocd-guide' hkl@192.168.3.5:/home/hkl/

& "$puttyTools\plink.exe" -ssh -i "$sdmKey" `
  -hostkey 'SHA256:mJz76idu6OVdaDsWdEnO5u3PjoyGpaliUR2uQ/o55Qw' `
  hkl@192.168.3.5
```

The remaining commands run on **192.168.3.5** unless another host is named. They use existing Git, Python and kubectl; no new software is required.

```bash
kubectl -n sdm-lab get statefulset sdm
kubectl -n sdm-lab get pod sdm-0 -o wide
kubectl -n sdm-lab get service,pvc,networkpolicy
kubectl -n argocd get applications
```

Confirm SDM has one ready replica and there is no existing Argo CD Application named `sdm-lab`. If SDM has changed materially from the table above or is already tracked by another Application, stop and reconcile that before adoption.

## 2 Create a separate local checkout

Clone the SDM repository into a new directory. Keep private working files outside the checkout.

```bash
umask 077
mkdir -p /home/hkl/.sdm-gitops-private
chmod 700 /home/hkl/.sdm-gitops-private

cd /home/hkl
git clone https://github.com/hklier/sdm-K8s.git sdm-K8s-gitops
cd /home/hkl/sdm-K8s-gitops
git checkout -B main
```

An empty-repository warning is expected for this first clone. If the repository is no longer empty, review its existing contents before continuing. The exporter refuses to overwrite an existing `deploy` directory.

Record the running pod identity and configuration for the adoption comparison. These files remain outside Git:

```bash
kubectl -n sdm-lab get pod sdm-0 -o jsonpath='{.metadata.uid}' \
  > /home/hkl/.sdm-gitops-private/pod-uid-before
kubectl -n sdm-lab get statefulset sdm -o json \
  > /home/hkl/.sdm-gitops-private/statefulset-before.json
kubectl -n sdm-lab get service sdm -o json \
  > /home/hkl/.sdm-gitops-private/service-before.json
```

Keep your existing SDM backup and recovery procedure available. The snapshots above describe Kubernetes resources; they are not database backups.

## 3 Export the existing resources into the checkout

```bash
python3 /home/hkl/github-argocd-guide/export-live.py \
  --repo /home/hkl/sdm-K8s-gitops

mkdir -p deploy/argocd image docs
cp /home/hkl/github-argocd-guide/project.yaml deploy/argocd/
cp /home/hkl/github-argocd-guide/application.yaml deploy/argocd/
cp /home/hkl/github-argocd-guide/image/Containerfile image/
cp /home/hkl/github-argocd-guide/image/entrypoint.sh image/
cp /home/hkl/github-argocd-guide/image/openssl-wrapper.sh image/
cp /home/hkl/github-argocd-guide/image/.containerignore image/
cp /home/hkl/github-argocd-guide/README.md docs/argocd-adoption.md
```

The exporter captures the current StatefulSet, two Services, PVC and network policies. It removes status, resource versions, managed fields and the previous kubectl apply annotation. It leaves the pod template unchanged. It also requests the currently assigned MetalLB address explicitly so it is represented in Git.

The PVC and all other adopted resources receive `Prune=false,Delete=false` annotations. The initial Application uses manual sync, server-side apply and shared-resource detection. These settings provide a deliberate first handover; they are not a guarantee against a human deleting Kubernetes objects. [Argo CD sync options](https://argo-cd.readthedocs.io/en/stable/user-guide/sync-options/).

The namespace, PV, StorageClass and Calico reservation are exported under `deploy/bootstrap-reference` for reference. They are **not** listed in the Application's Kustomization and are not reconciled by this Application. The host directory and existing credential Secret also remain outside Argo CD ownership.

Create the repository's ignore file and short overview:

```bash
cat > .gitignore <<'EOF'
.env
*.log
*.tar
*.tar.gz
*.tgz
*.oci
*.ppk
*.key
*.p12
*.jks
*.truststore
*setup.properties
*credential*
*token*
data/
private/
__pycache__/
EOF

cat > README.md <<'EOF'
# SDM Kubernetes lab

GitOps configuration for one existing Oracle SDM 9.0.5 lab instance.

- deploy/kubernetes/lab: namespaced resources reconciled by Argo CD
- deploy/argocd: AppProject and Application bootstrap configuration
- deploy/bootstrap-reference: existing infrastructure inventory, outside the Application
- image: build recipe and container adapters, without the Oracle installer or image layers
- docs/argocd-adoption.md: manual handover and maintenance procedure

The image is referenced by immutable registry digest. Credentials and SDM data are not stored in Git.
EOF
```

The resulting layout is:

```text
sdm-K8s-gitops/
  README.md
  .gitignore
  deploy/
    argocd/application.yaml
    argocd/project.yaml
    bootstrap-reference/*.json
    kubernetes/lab/kustomization.yaml
    kubernetes/lab/*.json
  image/Containerfile
  image/entrypoint.sh
  image/openssl-wrapper.sh
  image/.containerignore
  docs/argocd-adoption.md
```

## 4 Review the desired state before publishing it

```bash
cd /home/hkl/sdm-K8s-gitops
kubectl kustomize deploy/kubernetes/lab \
  > /home/hkl/.sdm-gitops-private/sdm-rendered.yaml

cat deploy/kubernetes/lab/kustomization.yaml
cat deploy/kubernetes/lab/statefulset-sdm.json
cat deploy/kubernetes/lab/service-sdm.json
cat deploy/argocd/project.yaml
cat deploy/argocd/application.yaml

kubectl diff --server-side --field-manager=argocd-controller \
  -k deploy/kubernetes/lab
```

`kubectl diff` exit code 1 means differences were found. It does not apply them. For the initial adoption, expect retention annotations and the MetalLB requested-address annotation. Investigate any change to the pod template, image, replica count, service ports, PVC binding, pod IP or worker placement before continuing. Do not use Force or Replace to make the first sync succeed.

Review and stage only the intended files:

```bash
git status --short
git add .gitignore README.md deploy image docs
git diff --cached --stat
git diff --cached
```

Confirm the staged files contain no Secret resource, token, setup password, private key, Oracle installer or database. The snapshot includes only the existing Secret's name as a workload reference.

## 5 Commit and push to GitHub manually

For the initial commit, enter the author identity you want recorded:

```bash
read -rp 'Git author name: ' SDM_GIT_NAME
read -rp 'Git author email: ' SDM_GIT_EMAIL
git -c user.name="$SDM_GIT_NAME" -c user.email="$SDM_GIT_EMAIL" \
  commit -m 'Describe the existing SDM lab for Argo CD'

GIT_TERMINAL_PROMPT=1 git -c credential.helper= push -u origin main
```

At Git's prompts, enter username `hklier` and paste the PAT from your local `data/git_sdm-k8s.txt` as the password. Enter only the token text. Git does not echo this password; the command does not save it in a credential helper. Do not embed it in the remote URL or commit the credential file.

The repository is public, so cloning and Argo CD reading do not require that token. Your push does. Open [the repository](https://github.com/hklier/sdm-K8s) and confirm the first commit and deployment files are present.

## 6 Register the separate SDM Application

On the administration host, create the new project and Application using the reviewed files:

```bash
kubectl apply -f deploy/argocd/project.yaml
kubectl apply -f deploy/argocd/application.yaml

kubectl -n argocd annotate application sdm-lab \
  argocd.argoproj.io/refresh=hard --overwrite

kubectl -n argocd get application sdm-lab
kubectl -n argocd get application sdm-lab -o jsonpath='{.status.conditions}'
echo
```

This project is limited to the SDM namespace and the four namespaced resource kinds in the exported manifests. It does not allow management of PVs, StorageClasses, Secrets or cluster-wide Calico resources. It does not change any existing Application or project.

Open **https://192.168.2.243/** and sign in using your existing Argo CD account. Select `sdm-lab`, refresh it and review its Diff. It may initially show OutOfSync because the resources do not yet carry Argo CD tracking metadata.

No new GitHub repository Secret should be necessary because this repository is public. If a repository-access error appears, inspect that condition first. Do not copy the GitHub push token into the SDM namespace. [Argo CD repository configuration](https://argo-cd.readthedocs.io/en/stable/user-guide/private-repositories/).

## 7 Perform the first sync without pruning

After reviewing the Diff, request a manual sync. This command uses the existing kubectl client; it does not require installing the Argo CD CLI.

```bash
kubectl -n argocd patch application sdm-lab --type=merge \
  -p '{"operation":{"sync":{"prune":false}}}'

kubectl -n argocd get application sdm-lab -w
```

Press Ctrl+C after the sync finishes. Inspect the result:

```bash
kubectl -n argocd get application sdm-lab \
  -o jsonpath='{.status.operationState.phase}{"\n"}{.status.operationState.message}{"\n"}{.status.sync.status}{"\n"}{.status.health.status}{"\n"}'

kubectl -n sdm-lab get statefulset,pod,service,pvc
```

Expect a successful operation, Synced status and Healthy workload. If it fails, inspect the Application condition and failed resource. Do not delete the existing SDM workload or PVC to retry adoption.

## 8 Verify the existing instance was retained

```bash
BEFORE_UID="$(cat /home/hkl/.sdm-gitops-private/pod-uid-before)"
AFTER_UID="$(kubectl -n sdm-lab get pod sdm-0 -o jsonpath='{.metadata.uid}')"
printf 'Pod UID before: %s\nPod UID after:  %s\n' "$BEFORE_UID" "$AFTER_UID"
test "$BEFORE_UID" = "$AFTER_UID"

kubectl -n sdm-lab get pod sdm-0 -o wide
kubectl -n sdm-lab get service sdm -o wide
kubectl -n sdm-lab get pvc sdm-data
kubectl -n sdm-lab get statefulset sdm \
  -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'

curl -kfSs --max-time 20 https://192.168.0.240:8443/ \
  | grep '<title>Session Delivery Manager</title>'
```

For an unchanged first handover, the pod UID should remain the same. A different UID indicates the pod was recreated; review events and restart reasons rather than assuming adoption caused no interruption. Confirm the pod IP is still `10.244.194.67`, the LoadBalancer is still `192.168.0.240`, and you can sign in with your existing SDM credentials.

## 9 Make future changes through Git

Edit the appropriate file in `deploy/kubernetes/lab`, review the diff, commit and push. Do not run the original generator over this checkout: that would replace the captured live settings and could change the Service type or IP.

```bash
cd /home/hkl/sdm-K8s-gitops
git pull --ff-only
# Edit the intended manifest with your editor.
git diff
kubectl kustomize deploy/kubernetes/lab \
  > /home/hkl/.sdm-gitops-private/sdm-rendered.yaml
kubectl diff --server-side --field-manager=argocd-controller \
  -k deploy/kubernetes/lab

git add deploy/kubernetes/lab
git -c user.name="$SDM_GIT_NAME" -c user.email="$SDM_GIT_EMAIL" \
  commit -m 'Update SDM lab configuration'
GIT_TERMINAL_PROMPT=1 git -c credential.helper= push
```

Refresh and sync the Application manually as in steps 6–7. Under `OnDelete`, a pod-template change is applied to the StatefulSet but the running pod stays on its previous template until a controlled restart. Service and network-policy changes can take effect immediately when synced.

For a planned restart after a compatible configuration change, use Argo CD's resource restart action or this controlled pod deletion after the sync has succeeded:

```bash
kubectl -n sdm-lab delete pod sdm-0 --wait=true --timeout=240s
kubectl -n sdm-lab wait --for=condition=Ready pod/sdm-0 --timeout=1200s
kubectl -n sdm-lab get pod sdm-0 -o wide
```

This interrupts the single instance. It retains the StatefulSet, PVC, local data, reserved IP and credential Secret. Do not use force deletion. A restart with a new image still does not perform an SDM software/database upgrade automatically.

The Application and AppProject files are bootstrapped separately: Argo CD watches only `deploy/kubernetes/lab`. After changing `deploy/argocd/application.yaml` or `project.yaml` in Git, explicitly apply those bootstrap files again.

## 10 Optionally enable automatic reconciliation later

Manual sync is a valid managed setup. If you later want automatic synchronization after a push, edit `deploy/argocd/application.yaml` and add the following under `spec.syncPolicy`, keeping the existing `syncOptions`:

```yaml
automated:
  enabled: true
  prune: false
  selfHeal: true
```

Commit and push that bootstrap-file change, then apply it explicitly:

```bash
git add deploy/argocd/application.yaml
git -c user.name="$SDM_GIT_NAME" -c user.email="$SDM_GIT_EMAIL" \
  commit -m 'Enable SDM reconciliation without pruning'
GIT_TERMINAL_PROMPT=1 git -c credential.helper= push
kubectl apply -f deploy/argocd/application.yaml
```

Self-healing can undo direct kubectl changes to managed fields, including manual replica changes. Put an intended shutdown or configuration change in Git when automatic reconciliation is enabled. The resource retention annotations continue to prevent Argo CD pruning/deletion of the adopted objects. [Automatic synchronization behavior](https://argo-cd.readthedocs.io/en/stable/user-guide/auto_sync/).

## 11 Roll back a manifest change through Git

For a configuration-only change that can safely be reversed:

```bash
git log --oneline -5
read -rp 'Commit SHA to revert: ' SDM_REVERT_COMMIT
git revert "$SDM_REVERT_COMMIT"
GIT_TERMINAL_PROMPT=1 git -c credential.helper= push
```

Refresh and sync the reverted state. If a pod template changed under `OnDelete`, schedule the necessary controlled restart. A manifest rollback does not restore an upgraded database or the installed application tree on the PVC; use the SDM recovery procedure for that case.

## 12 Optional private GitHub Container Registry package

Skip this section if you want to keep using the existing image in `192.168.2.240:5000`. GitHub and Argo CD can manage the lab without moving the image.

If you want the image hosted by GitHub as well, use a **private** GHCR package, `ghcr.io/hklier/sdm-k8s`. The Git repository being public does not require the package to be public. GHCR currently uses a personal access token **classic** for command-line authentication: a publishing token needs `write:packages`; the cluster pull token needs only `read:packages`. The repository token is not automatically suitable for these operations. [GitHub Container Registry authentication and visibility](https://docs.github.com/en/packages/working-with-a-github-packages-registry/working-with-the-container-registry).

### Publish from the image build host

On **192.168.3.53**, using its existing Podman installation:

```bash
umask 077
SDM_SOURCE_IMAGE='192.168.2.240:5000/sdm-lab@sha256:78edaf080feec31cfe163e57cbe768b96f6250915897b74ac77ce0d0f277aead'
sudo podman pull --tls-verify=false "$SDM_SOURCE_IMAGE"
SDM_AUTHFILE="$(mktemp)"
read -rsp 'GHCR publishing token: ' GHCR_WRITE_TOKEN
echo
printf '%s' "$GHCR_WRITE_TOKEN" | sudo podman login \
  --authfile "$SDM_AUTHFILE" -u hklier --password-stdin ghcr.io
unset GHCR_WRITE_TOKEN

sudo podman push --authfile "$SDM_AUTHFILE" \
  --digestfile /home/hkl/sdm-container-lab/ghcr-image.digest \
  "$SDM_SOURCE_IMAGE" \
  docker://ghcr.io/hklier/sdm-k8s:9.0.5-ol9

sudo rm -f -- "$SDM_AUTHFILE"
unset SDM_AUTHFILE
cat /home/hkl/sdm-container-lab/ghcr-image.digest
```

Use GitHub's Packages page to confirm the new package is **Private** and connect it to repository `hklier/sdm-K8s`. A command-line push does not automatically connect the package to a repository. Do not change the package to Public as part of this lab procedure.

The source reference above is the running image observed on 6 November. If step 8 reports a different current reference, substitute that exact digest before the pull and push. Pulling from the lab registry by digest avoids publishing an unrelated local tag accidentally.

### Create a pull credential outside Git

On **192.168.3.5**, use a read-only package token. The temporary Docker configuration stays in the private working directory:

```bash
umask 077
read -rsp 'GHCR read packages token: ' GHCR_READ_TOKEN
echo
export GHCR_READ_TOKEN
python3 - <<'PY'
import base64, json, os
from pathlib import Path
auth = base64.b64encode(('hklier:' + os.environ['GHCR_READ_TOKEN']).encode()).decode()
p = Path('/home/hkl/.sdm-gitops-private/ghcr-config.json')
with p.open('w') as f:
    json.dump({'auths': {'ghcr.io': {'auth': auth}}}, f)
p.chmod(0o600)
PY
unset GHCR_READ_TOKEN

kubectl -n sdm-lab create secret generic ghcr-pull \
  --type=kubernetes.io/dockerconfigjson \
  --from-file=.dockerconfigjson=/home/hkl/.sdm-gitops-private/ghcr-config.json
rm -f /home/hkl/.sdm-gitops-private/ghcr-config.json
```

This Secret remains outside Argo CD ownership and Git. If it already exists, inspect your credential-rotation process instead of repeatedly creating it.

### Change the Git image reference

Copy the manifest digest printed on the build host into this prompt. It is not a password. The GHCR digest can differ from the previous lab-registry digest.

```bash
cd /home/hkl/sdm-K8s-gitops
read -rp 'Published GHCR manifest digest, starting sha256: ' GHCR_IMAGE_DIGEST
export GHCR_IMAGE_DIGEST
python3 - <<'PY'
import json, os, re
from pathlib import Path
d = os.environ['GHCR_IMAGE_DIGEST']
if not re.fullmatch(r'sha256:[a-f0-9]{64}', d):
    raise SystemExit('Invalid manifest digest')
p = Path('deploy/kubernetes/lab/statefulset-sdm.json')
x = json.loads(p.read_text())
pod = x['spec']['template']['spec']
pod['containers'][0]['image'] = 'ghcr.io/hklier/sdm-k8s@' + d
pod['imagePullSecrets'] = [{'name': 'ghcr-pull'}]
p.write_text(json.dumps(x, indent=2) + '\n')
PY
unset GHCR_IMAGE_DIGEST

git diff
git add deploy/kubernetes/lab/statefulset-sdm.json
git -c user.name="$SDM_GIT_NAME" -c user.email="$SDM_GIT_EMAIL" \
  commit -m 'Reference the private GHCR SDM package'
GIT_TERMINAL_PROMPT=1 git -c credential.helper= push
```

Refresh and sync Argo CD, then perform the planned restart in step 9. Verify Ready status and the image reference. GitHub repository credentials, package pull credentials and the SDM setup credentials serve different purposes; retain each separately.

## Troubleshooting

```bash
kubectl -n argocd get application sdm-lab -o yaml
kubectl -n argocd get application sdm-lab \
  -o jsonpath='{.status.conditions}{"\n"}{.status.operationState.message}{"\n"}'
kubectl -n sdm-lab describe pod sdm-0
kubectl -n sdm-lab get events --sort-by=.lastTimestamp
kubectl -n sdm-lab logs sdm-0 --tail=100
```

- **Repository not found or authentication failure:** verify the canonical URL `https://github.com/hklier/sdm-K8s.git`, a populated `main` branch and Argo CD network access. The repository was public when checked.
- **Shared resource error:** find the existing Application owner; do not force another Application to take the same object.
- **Immutable-field error:** compare the original live resource snapshot. Do not delete the PVC, StatefulSet or Service to bypass a configuration mismatch.
- **AppProject denies a resource:** the managed path should contain only SDM's namespaced StatefulSet, Services, PVC and network policies. Bootstrap reference files must remain outside its Kustomization.
- **ImagePullBackOff after GHCR migration:** verify package visibility/access, the `ghcr-pull` Secret and the exact registry manifest digest. Argo CD's Git access does not grant a worker permission to pull private images.
- **New digest synced but old SDM version still runs:** the installed application is persisted on the PVC. Follow the SDM software upgrade procedure; changing the image reference is not sufficient.

Do not add a GitHub Actions build that expects the Oracle installer to exist in this public repository. Automated builds would require a separately designed private installer source and credentials. The initial procedure needs no workflow or new cluster component.
