# dummy-app-template

A reusable Kustomize-based template for deploying a new application to the Homelab-0 K3s cluster.

This template follows the cluster conventions already established:

- **K3s** with **Traefik** as the Ingress controller
- **cert-manager** for TLS
- **Dev** and **Prod** deployed in separate namespaces
- Stable internal Kubernetes object names across environments
- Environment differences handled by:
    - namespace
    - hostname
    - cert-manager issuer
    - optional replica/image overrides

---

## Conventions

### Namespaces

- **Dev:** `apps-dev`
- **Prod:** `apps-prod`

### Hostnames

- **Dev:** `dev.<app>.kakde.eu`
- **Prod:** `<app>.kakde.eu`

Example for an app named `my-api`:

- Dev: `dev.my-api.kakde.eu`
- Prod: `my-api.kakde.eu`

### TLS Issuers

- **Dev / staging:** `letsencrypt-staging-dns01`
- **Prod:** `letsencrypt-prod-dns01`

### Important Traefik requirements for this cluster

Every Ingress must include:

- `spec.ingressClassName: traefik`
- `metadata.annotations["kubernetes.io/ingress.class"]: traefik`
- `metadata.annotations["traefik.ingress.kubernetes.io/router.tls"]: "true"`

Without `router.tls: "true"`, HTTPS requests may return a Traefik 404 in this cluster.

### Golden rules

- Do **not** use `nameSuffix: -dev`
- Keep internal object names identical across dev and prod
- Separate environments by namespace, not by renaming objects
- Use `ClusterIP` Services behind Traefik
- Keep Ingress and Service in the same namespace

---

## Directory structure

```text
dummy-app-template/
├── base/
│   ├── deployment.yaml
│   ├── service.yaml
│   └── kustomization.yaml
├── overlays/
│   ├── dev/
│   │   ├── ingress.yaml
│   │   └── kustomization.yaml
│   └── prod/
│       ├── ingress.yaml
│       └── kustomization.yaml
└── scripts/
    ├── render.sh
    ├── apply.sh
    ├── verify.sh
    └── cleanup-old-from-apps.sh