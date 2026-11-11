# SDM on KubeVirt

One Oracle Linux 9.7 VM running SDM 9.0.5 on worker1, with 4 vCPUs, 24 GiB RAM and a persistent 100 GiB OS disk. This reduced disk size is an explicit lab choice.

Access: SSH `hkl@192.168.0.240` with the existing hkl key, and HTTPS `https://192.168.0.240:8443/`. The management-network ingress policy permits 192.168.0.0/22. Root Linux access uses `sudo`; SSH passwords/root login are disabled.

The VM and Service are managed by Argo CD. SDM installation and application upgrades happen inside the VM; changing a Git manifest does not reinstall or upgrade SDM. VM data is retained; automatic pruning is disabled.

Infrastructure bootstrap manifests are in `bootstrap/kubevirt/`. KubeVirt v1.9.1 and CDI v1.66.1 are installed from their official release operator manifests. The dedicated 300 GiB worker1 disk is mounted by UUID at `/var/lib/sdm-kubevirt`; the VM volume is `/var/lib/sdm-kubevirt/sdm-os`. The VM is pinned to worker1 and does not provide HA or live migration.

Vendor installation media and credentials must not be committed to Git. Credentials are held inside the VM at `/root/sdm-lab-credentials.txt`, readable with sudo. Service control: `sudo systemctl status sdm`. Previous container manifests are archived under `archive/container-lab-retired-20261111/`.

The OS DataVolume uses native CDI upload. Run `operations/kubevirt/download-base.py` on the master to stage the pinned official Oracle image and record its checksum, then upload it once using `virtctl -n sdm-lab image-upload dv sdm-os --no-create --image-path=/home/hkl/sdm-kubevirt/cache/OL9U7_x86_64-kvm-b269.qcow2 --uploadproxy-url=https://<cdi-uploadproxy-cluster-ip>:443 --insecure`. The insecure flag applies only to the cluster-local CDI proxy self-signed certificate. This bootstrap step is necessary only for a new empty OS volume; it must not overwrite an existing SDM VM disk.

The guest hostname `sdm-kubevirt` resolves to its persistent masquerade-interface address `10.0.2.2`, not to loopback. Preserve this mapping: SDM binds its encoded R226 setting to the local hostname/address. The `sdm` systemd unit waits for HTTPS readiness and uses the noninteractive single-node shutdown option `-local`. Plug-ins are installed using `operations/kubevirt/install-plugins.py`; their files and database reside on the retained guest OS volume.

Validation on 2026-11-11: a complete VM restart preserved the installation and all three installed plug-ins (Enterprise Edge & Core, Enterprise Utilities, SP Edge & Core). SDM started automatically, HTTPS and authenticated REST checks passed, the trap listener bound to `10.0.2.2:162`, and HTTPS through `192.168.0.240:8443` returned 200. Run `sudo python3 verify-sdm.py` inside the guest for read-only checks after copying `operations/kubevirt/verify-sdm.py` there. No SBC has been registered in this fresh installation.
