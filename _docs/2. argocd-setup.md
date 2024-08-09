https://argo-cd.readthedocs.io/en/stable/getting_started/

### Install Argo CD
```bash
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
```
<hr>

### Download Argo CD CLI for Mac, Linux and WSL Homebrew:
```bash
brew install argocd
```
<hr>

### Access The Argo CD API Server

1. Port Forwarding

Simplest and easiest way to connect to the API server without exposing the service is by using Kubectl port-forwarding.
```bash
kubectl port-forward svc/argocd-server -n argocd 4000:443
```
OR
```bash
POD_NAME=$(kubectl get pods -n argocd | grep "^argocd-server-" | cut -d' ' -f1)
kubectl port-forward pods/$POD_NAME -n argocd 4000:8080
```
The API server can then be accessed using https://localhost:4000

2. Ingress: https://argo-cd.readthedocs.io/en/stable/operator-manual/ingress/

<hr>

### Login Using The CLI

Initially simply retrieve password using the argocd CLI:
```bash
argocd admin initial-password -n argocd
```

### Login into account:

```bash
argocd login localhost:4000
```

### Change the password using the command:
```bash
argocd account update-password
```