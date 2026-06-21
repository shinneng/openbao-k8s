#!/bin/bash
set -euo pipefail

# Usage: ./retrieve-and-run.sh <playbook_path> [optional_private_key_path]
PLAYBOOK="${1:-}"
PRIV_KEY="${2:-$HOME/.ssh/id_rsa}" 
PUB_KEY="${PRIV_KEY}.pub"

if [ -z "$PLAYBOOK" ]; then
    echo "ERROR: Missing required playbook argument." >&2
    echo "Usage: $0 <playbook_path> [private_key_path]" >&2
    exit 1
fi

export BAO_ADDR="${BAO_ADDR:-https://example.com}"
SSH_ENGINE_PATH="ssh-client-signer"  # Target path for native SSH engine
SSH_ROLE="ansible-admin-role"       # Pre-configured OpenBao SSH engine role

# Check required local binaries
for cmd in bao jq ansible-playbook; do
    if ! command -v "$cmd" &> /dev/null; then
        echo "ERROR: Required command '$cmd' is not installed." >&2
        exit 1
    fi
done

# 1. Authenticate check
if ! bao token lookup > /dev/null 2>&1; then
    echo "ERROR: Please login to OpenBao first (e.g., bao login -method=oidc)" >&2
    exit 1
fi

# 2. Verify local cryptographic keys exist before attempting signing
if [ ! -f "$PRIV_KEY" ] || [ ! -f "$PUB_KEY" ]; then
    echo "ERROR: Keypair not found at $PRIV_KEY. Run 'ssh-keygen' first." >&2
    exit 1
fi

echo "Requesting dynamic dynamic key signature from OpenBao..."

# 3. Setup temporary paths and safety structures
CERT_MATCH_PATH="${PRIV_KEY}-cert.pub"
BACKUP_MADE=false

if [ -f "$CERT_MATCH_PATH" ]; then
    echo "Warning: Existing cert found at $CERT_MATCH_PATH. Backing it up temporarily..."
    mv "$CERT_MATCH_PATH" "${CERT_MATCH_PATH}.bak"
    BACKUP_MADE=true
fi

# Cleanup Hook
cleanup() {
    echo "Performing disk cleanup..."
    if [ -f "$CERT_MATCH_PATH" ]; then
        rm -f "$CERT_MATCH_PATH"
    fi
    if [ "$BACKUP_MADE" = true ] && [ -f "${CERT_MATCH_PATH}.bak" ]; then
        mv "${CERT_MATCH_PATH}.bak" "$CERT_MATCH_PATH"
        echo "Restored original backup certificate."
    fi
}
trap cleanup EXIT INT TERM

# 4. Request dynamic cryptographic signature using OpenBao SSH Engine
# Reads the local public key string and sends it as a payload parameter
if ! SIGNED_DATA=$(bao write -format=json "${SSH_ENGINE_PATH}/sign/${SSH_ROLE}" \
    public_key=@"${PUB_KEY}" 2>/dev/null); then
    echo "ERROR: OpenBao failed to sign the public key. Check role permissions." >&2
    exit 1
fi

# Extract the certificate data out of the standard secret payload envelope
CERT_CONTENT=$(echo "$SIGNED_DATA" | jq -r '.data.certificate // empty')
if [ -z "$CERT_CONTENT" ] || [ "$CERT_CONTENT" == "null" ]; then
    echo "ERROR: Failed to extract valid signed certificate payload from response." >&2
    exit 1
fi

# Write the temporary JIT certificate map to the required target structure
echo "$CERT_CONTENT" > "$CERT_MATCH_PATH"
chmod 600 "$CERT_MATCH_PATH"
echo "Dynamic certificate issued successfully and mapped to $CERT_MATCH_PATH"

# 5. Run Ansible Playbook
echo "Executing Ansible Playbook..."
export ANSIBLE_SSH_ARGS="-o CertificateFile=$CERT_MATCH_PATH -o IdentityFile=$PRIV_KEY"
ansible-playbook -i ansible/inventory.yml "$PLAYBOOK"

echo "Done."
