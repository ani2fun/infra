cd ~/Development/homelab/infra

scripts/secrets/rotate-keycloak-github-oauth.sh <client-id> <new-client-secret>
scripts/secrets/rotate-generic-secret.sh <namespace> <secret-name> <output-yaml> key=value [key=value ...]

scripts/secrets/read-secret-value.sh identity keycloak-github-oauth client-id
scripts/secrets/read-keycloak-admin-credentials.sh
scripts/secrets/read-keycloak-db-password.sh
scripts/secrets/read-dsa-tracker-db-password.sh
