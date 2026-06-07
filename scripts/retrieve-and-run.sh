#!/bin/bash
set -e

# Usage: ./retrieve-and-run.sh <github_username> <playbook_path>

USER_GITHUB=$1
PLAYBOOK=$2

if [ -z "$USER_GITHUB" ] || [ -z "$PLAYBOOK" ]; then
    echo "Usage: $0 <github_username> <playbook_path>"
    exit 1
fi

export BAO_ADDR="https://bao.example.com"

# 1. Authenticate (User should already have a token or use 'bao login')
if ! bao token lookup > /dev/null 2>&1; then
    echo "Please login to OpenBao first (e.g., bao login -method=oidc)"
    exit 1
fi

echo "Fetching signed certificate for JIT access..."

# 2. Retrieve the certificate from the KV store
CERT_DATA=$(bao kv get -format=json ssh-certs/jit/${USER_GITHUB})
CERT_CONTENT=$(echo "$CERT_DATA" | jq -r .data.data.certificate)

# 3. Save to a temporary file
CERT_FILE=$(mktemp)
echo "$CERT_CONTENT" > "$CERT_FILE"
chmod 600 "$CERT_FILE"

# 4. Determine the matching private key (assumes ~/.ssh/id_rsa)
PRIV_KEY="$HOME/.ssh/id_rsa"
# Temporarily symlink or copy to match OpenBao's expectation (cert must be <key>-cert.pub)
CERT_MATCH_PATH="${PRIV_KEY}-cert.pub"
cp "$CERT_FILE" "$CERT_MATCH_PATH"

echo "Certificate retrieved and mapped to $CERT_MATCH_PATH"

# 5. Run Ansible
echo "Executing Ansible Playbook..."
ansible-playbook -i ansible/inventory.yml "$PLAYBOOK"

# 6. Cleanup (Optional: delete from OpenBao after use for true JIT)
echo "Cleaning up..."
rm "$CERT_MATCH_PATH"
# bao kv delete ssh-certs/jit/${USER_GITHUB}

echo "Done."
