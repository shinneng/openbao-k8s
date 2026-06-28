# Testing OpenBao SSH CA

This guide walks through the step-by-step process of testing OpenBao's SSH Certificate Authority (SSH CA) using a dedicated target pod in the cluster.

---

## 1. Setup the Target SSH Server Pod

A test pod running an SSH server must be deployed and configured to trust the OpenBao client CA.

If you haven't deployed the target pod yet, use the manifest [ssh-test-target.yaml](../ssh-test-target.yaml):

```bash
kubectl apply -f ssh-test-target.yaml
```

The pod startup script automatically:
1. Installs `openssh-server` and `curl`.
2. Creates a user account named `ubuntu` (password login disabled, key-based authentication only).
3. Fetches the OpenBao SSH Client CA public key from the unauthenticated endpoint:
   `https://openbao.openbao.svc:8200/v1/ssh-client-signer/public_key`
4. Writes the CA key to `/etc/ssh/trusted-user-ca-keys.pem` and configures `sshd` to trust it using `TrustedUserCAKeys`.

Verify that the pod is running and has initialized successfully:
```bash
kubectl get pods -n openbao -l app=ssh-test-target
kubectl logs -n openbao ssh-test-target --tail 20
```
*Expected log output should end with `Server listening on 0.0.0.0 port 22.`*

---

## 2. Generate and Sign your Client SSH Key

Follow these steps on your local client machine:

### Step 2a: Generate a Test SSH Key Pair
Create a temporary SSH key pair locally:
```bash
ssh-keygen -t rsa -b 4096 -f ./test_id_rsa -N ""
```

### Step 2b: Port-Forward the OpenBao Service
Expose the OpenBao API locally (run in a separate terminal window or in the background):
```bash
kubectl port-forward -n openbao svc/openbao 8200:8200
```

### Step 2c: Authenticate & Sign your Public Key
Configure your environment to point to OpenBao, retrieve the root token, and request a signed certificate for the principal `ubuntu` using the `production-role`:

```bash
# Configure OpenBao CLI environment
export BAO_ADDR="https://127.0.0.1:8200"
export BAO_SKIP_VERIFY=true

# Fetch the root token from the Kubernetes secret
export BAO_TOKEN=$(kubectl get secret -n openbao openbao-root-token -o jsonpath='{.data.token}' | base64 --decode)

# Sign the public key and save the certificate
bao write -field=signed_key ssh-client-signer/sign/production-role \
    public_key=@./test_id_rsa.pub \
    valid_principals="ubuntu" > ./test_id_rsa-cert.pub
```

### Step 2d: Inspect the Signed Certificate
You can inspect the metadata of the newly created certificate file using `ssh-keygen`:
```bash
ssh-keygen -Lf ./test_id_rsa-cert.pub
```
Verify that:
* **Type** is `user certificate`.
* **Principals** lists `ubuntu`.
* The validity period is active.

---

## 3. SSH into the Target Pod

### Step 3a: Port-Forward the SSH Server
Expose the SSH daemon port on the test pod locally (run in a separate terminal window or in the background):
```bash
kubectl port-forward -n openbao pod/ssh-test-target 2222:22
```

### Step 3b: Connect
Run the `ssh` command using the signed certificate to authenticate:
```bash
ssh -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o IdentitiesOnly=yes \
    -i ./test_id_rsa \
    -i ./test_id_rsa-cert.pub \
    -p 2222 \
    ubuntu@127.0.0.1
```

> [!NOTE]
> The `-o IdentitiesOnly=yes` flag ensures that the SSH client only attempts the keys specified by the `-i` flag, preventing any local keys from your SSH agent from triggering "Too many authentication failures" on the server.

If successful, you will log straight in as the `ubuntu` user without any password prompts or pre-shared keys!

---

## 4. Testing with Ansible Playbook

You can test the Ansible playbook `setup-ca.yml` to automatically configure the SSH server to trust OpenBao's CA.

### Step 4a: Start the Pod and Port-Forward
First, deploy the updated target pod (which starts up *without* CA trust configured) and port-forward port 22:
```bash
kubectl apply -f ssh-test-target.yaml
kubectl port-forward -n openbao pod/ssh-test-target 2222:22
```

### Step 4b: Verify CA is not trusted initially
If you attempt to SSH using a signed certificate *before* running the playbook, it will fail (or prompt for password):
```bash
ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o IdentitiesOnly=yes -i ./test_id_rsa -i ./test_id_rsa-cert.pub -p 2222 ubuntu@127.0.0.1
# Result: Password prompt (since trust isn't configured yet)
```

### Step 4c: Port-Forward the OpenBao API
Ensure OpenBao is accessible locally so the playbook can read the public key:
```bash
kubectl port-forward -n openbao svc/openbao 8200:8200
```
Then export the connection environment variables (or ensure your local `bao` CLI is logged in):
```bash
export BAO_ADDR="https://127.0.0.1:8200"
export BAO_SKIP_VERIFY=true
export BAO_TOKEN=$(kubectl get secret -n openbao openbao-root-token -o jsonpath='{.data.token}' | base64 --decode)
```

### Step 4d: Run the Playbook
Run the Ansible playbook using the provided test inventory `ansible/test-inventory.ini`:
```bash
ansible-playbook -i ansible/test-inventory.ini ansible/setup-ca.yml --extra-vars "bao_addr=$BAO_ADDR"
```

*Note: Since the pod runs inside a container, a mock service helper `/usr/sbin/service` intercepts the `service ssh restarted` call from Ansible and reloads `sshd` without terminating the container.*

### Step 4e: Verify SSH Certificate Authentication
After the playbook completes successfully, verify that the SSH server now trusts the OpenBao CA by connecting using your signed certificate:
```bash
ssh -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o IdentitiesOnly=yes \
    -i ./test_id_rsa \
    -i ./test_id_rsa-cert.pub \
    -p 2222 \
    ubuntu@127.0.0.1
```
You should log straight in without any password prompt!
