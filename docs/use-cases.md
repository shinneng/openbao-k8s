# OpenBao Use Cases: SSH CA & PII Tokenization

This document explains how to implement the requested use cases using the deployed OpenBao HA stack.

## 1. SSH CA (Certificate Authority)

### 1a. User SSH CA

OpenBao can act as an SSH Certificate Authority to manage access to servers without distributing static public keys.

### Configuration

1. **Enable SSH Secrets Engine**:
   ```bash
   bao secrets enable -path=ssh-client-signer ssh
   ```

2. **Configure CA Key**:
   ```bash
   bao write ssh-client-signer/config/ca generate_signing_key=true
   ```

3. **Create a Role**:
   ```bash
   bao write ssh-client-signer/roles/production-role @- <<EOF
   {
     "allow_user_certificates": true,
     "allowed_users": "*",
     "default_extensions": {
       "permit-pty": ""
     },
     "key_type": "ca",
     "default_user": "ubuntu",
     "ttl": "30m0s"
   }
   EOF
   ```

4. **Sign a Public Key**:
   ```bash
   bao write ssh-client-signer/sign/production-role \
       public_key=@$HOME/.ssh/id_rsa.pub > signed-key.pub
   ```

---

## 2. Tokenization for PII (Transit Engine)

The Transit engine handles cryptographic functions on data in-transit but doesn't store the data. This is ideal for tokenizing/encrypting PII before storing it in PostgreSQL.

### Configuration

1. **Enable Transit Secrets Engine**:
   ```bash
   bao secrets enable transit
   ```

2. **Create Encryption Key**:
   ```bash
   bao write -f transit/keys/pii-data-key
   ```

3. **Encrypt Data (Tokenization)**:
   ```bash
   # Input: "Sensitive PII Info" base64 encoded
   bao write transit/encrypt/pii-data-key \
       plaintext=$(echo "Sensitive PII Info" | base64)
   
   # Response will contain a ciphertext like "bao:v1:..."
   ```

4. **Decrypt Data**:
   ```bash
   bao write transit/decrypt/pii-data-key \
       ciphertext="bao:v1:xyz..."
   ```

---

## 3. External Connectivity (Outside Cluster)

To connect an application running outside the Kubernetes cluster to OpenBao, you use the Istio Ingress Gateway.

### Access via Gateway

1. **Endpoint**: The application should point to the public DNS name (e.g., `https://bao.example.com`) or the LoadBalancer IP of the `istio-ingressgateway` Service.
2. **TLS**: Use a trusted CA. If using the self-signed cert from this setup, the application must trust the CA provided by cert-manager.

### Recommended Authentication: AppRole

For external machine-to-machine authentication, **AppRole** is the standard.

1. **Enable AppRole**:
   ```bash
   bao auth enable approle
   ```

2. **Create a Policy**:
   ```bash
   bao policy write web-app - <<EOF
   path "transit/encrypt/pii-data-key" { capabilities = ["update"] }
   EOF
   ```

3. **Create an AppRole**:
   ```bash
   bao write auth/approle/role/web-app \
       secret_id_ttl=10m \
       token_num_uses=10 \
       token_ttl=20m \
       token_max_ttl=30m \
       policies="web-app"
   ```

4. **External App Login**:
   The external app first fetches its `role-id` and `secret-id`, then logs in:
   ```bash
   # Get Role ID (usually pre-configured in the app)
   ROLE_ID=$(bao read -format=json auth/approle/role/web-app/role-id | jq -r .data.role_id)
   
   # Get Secret ID (one-time use or TTL based)
   SECRET_ID=$(bao write -f -format=json auth/approle/role/web-app/secret-id | jq -r .data.secret_id)

   # Login from external app
   bao write auth/approle/login role_id="$ROLE_ID" secret_id="$SECRET_ID"
   ```

---

## 4. TLS for OpenBao Agent

The OpenBao Agent (injected as a sidecar) can handle authentication and secret caching. In the HelmRelease, we've configured the injector to use TLS.

### Agent Config Snippet
When using the `bao.hashicorp.com/agent-inject` annotation, ensure you provide the CA:

```yaml
annotations:
  bao.hashicorp.com/agent-inject: "true"
  bao.hashicorp.com/agent-inject-secret-config: "database/creds/db-app"
  bao.hashicorp.com/agent-inject-template-config: |
    {{ with secret "database/creds/db-app" }}
    export DB_USER="{{ .Data.username }}"
    export DB_PASS="{{ .Data.password }}"
    {{ end }}
  # TLS config for agent
  bao.hashicorp.com/agent-ca-cert: "/bao/userconfig/openbao-server-tls/ca.crt"
```
The sidecar will automatically mount the secret defined in the HelmRelease's `extraVolumes` if configured correctly, or you can use a separate InitContainer to fetch the CA.
