# SDM on KubeVirt

One Oracle Linux 9.7 VM running SDM 9.0.5 on worker1, with 4 vCPUs, 24 GiB RAM and a persistent 100 GiB OS disk. This reduced disk size is an explicit lab choice.

Access: SSH `hkl@192.168.0.240` with the existing hkl key, and HTTPS `https://192.168.0.240:8443/`. The management-network ingress policy permits 192.168.0.0/22. Root Linux access uses `sudo`; SSH passwords/root login are disabled.

The VM and Service are managed by Argo CD. SDM installation and application upgrades happen inside the VM; changing a Git manifest does not reinstall or upgrade SDM. VM data is retained; automatic pruning is disabled.

Infrastructure bootstrap manifests are in `bootstrap/kubevirt/`. KubeVirt v1.9.1 and CDI v1.66.1 are installed from their official release operator manifests. The dedicated 300 GiB worker1 disk is mounted by UUID at `/var/lib/sdm-kubevirt`; the VM volume is `/var/lib/sdm-kubevirt/sdm-os`. The VM is pinned to worker1 and does not provide HA or live migration.

Vendor installation media and credentials must not be committed to Git. Credentials are held inside the VM at `/root/sdm-lab-credentials.txt`, readable with sudo. Service control: `sudo systemctl status sdm`. Previous container manifests are archived under `archive/container-lab-retired-20261111/`.
