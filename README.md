# SDM Kubernetes lab

GitOps configuration for one existing Oracle SDM 9.0.5 lab instance.

- deploy/kubernetes/lab: namespaced resources reconciled by Argo CD
- deploy/argocd: AppProject and Application bootstrap configuration
- deploy/bootstrap-reference: existing infrastructure inventory, outside the Application
- image: build recipe and container adapters, without the Oracle installer or image layers
- docs/argocd-adoption.md: manual handover and maintenance procedure

The image is referenced by immutable registry digest. Credentials and SDM data are not stored in Git.
