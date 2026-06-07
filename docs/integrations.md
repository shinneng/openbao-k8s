# OpenBao Ansible Integrations

This guide explains how to integrate the OpenBao SSH CA and Ansible setup across different environments.

## 1. CLI Usage
For local execution, ensure your environment is configured:

```bash
export BAO_ADDR="https://bao.example.com"
export BAO_TOKEN="your-token-here"

# Sign your key
bao write -field=signed_key ssh-client-signer/sign/production-role \
    public_key=@$HOME/.ssh/id_rsa.pub > $HOME/.ssh/id_rsa-cert.pub

# Run Ansible
ansible-playbook -i inventory.yml playbook.yml
```

---

## 2. SemaphoreUI Integration

1. **Environment Variables**: In SemaphoreUI, go to **Credentials** and add a new credential of type **Environment Variables**.
   - `BAO_ADDR`: `https://bao.example.com`
   - `BAO_TOKEN`: (The sensitive token)
2. **Key Signing**: Add a **Task Template** with a "Pre-task" script to sign the public key:
   ```bash
   bao write -field=signed_key ssh-client-signer/sign/production-role \
       public_key=@/home/semaphore/.ssh/id_rsa.pub > /home/semaphore/.ssh/id_rsa-cert.pub
   ```
3. **Inventory**: Use the standard inventory. SSH certificates will be automatically used by the SSH client if the cert file name matches the key name (`id_rsa-cert.pub`).

---

## 3. AWX / Ansible Automation Platform

1. **Custom Credential Type**: Create a custom credential type for OpenBao if you want to manage tokens securely.
   - **Input Configuration**: `fields: [{id: token, type: string, secret: true}]`
   - **Injector Configuration**: `env: {BAO_TOKEN: "{{token}}"}`
2. **Execution Environment**: Ensure your Execution Environment (EE) image has the `bao` binary installed.
3. **Workflow**: Use an AWX **Workflow Job Template** where the first node is a "Sign Key" job and the second node is the actual deployment.

---

## 5. Automated Retrieval in GUI Platforms (SemaphoreUI / AWX)

For platforms where you cannot run a local shell script easily, use the [retrieve-cert.yml](file:///home/shinneng/code/openbao-k8s/ansible/retrieve-cert.yml) playbook as an initial step.

### Workflow
1. **User Request**: User triggers the JIT Approval workflow in GitHub and provides their public key.
2. **Approval**: The approver signs the key, and it is stored in OpenBao at `ssh-certs/jit/<github_user>`.
3. **Platform Execution**:
   - The user starts a job in SemaphoreUI or AWX.
   - The job is configured with the following environment variables:
     - `GITHUB_USER`: The username used in the JIT request.
     - `BAO_TOKEN`: A token with permission to read the `ssh-certs/` path.
   - **First Job/Task**: Run `ansible-playbook ansible/retrieve-cert.yml`. This script fetches the cert and saves it to the runner's SSH directory.
   - **Second Job/Task**: Run the actual deployment playbook. The SSH client will automatically pick up the certificate from the runner's disk.

### Security
The `retrieve-cert.yml` playbook uses `no_log: true` to ensure the sensitive certificate content does not appear in the platform's job logs.
