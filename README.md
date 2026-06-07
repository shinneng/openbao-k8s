# OpenBao GitOps Stack

A production-grade, highly available Kubernetes stack for secret management and secure Ansible automation, managed via FluxCD.

## 🚀 Overview

This repository provides a complete "Secrets-as-Code" infrastructure including:
- **OpenBao (HA)**: Distributed secret management with Raft and TLS.
- **Istio & Gateway API**: Secure ingress and global mTLS.
- **CloudNativePG**: High-availability PostgreSQL for application state.
- **SemaphoreUI**: Web interface for Ansible automation.
- **JIT SSH Access**: PIM-like Just-In-Time SSH signing with GitHub Actions approval gates.

## 📂 Directory Structure

```text
├── .github/workflows     # JIT Approval and CI/CD pipelines
├── ansible               # Playbooks for SSH CA and Cert retrieval
├── apps                  # High-level applications (OpenBao, Semaphore, External Secrets)
├── clusters/production   # FluxCD entry points for the production environment
├── docs                  # Detailed architecture and use-case guides
├── infrastructure       # Core infra (Istio, Cert-Manager, Gateway API, CNPG)
└── scripts              # Helper scripts for operators
```

## 🛠️ Key Features

### 1. High Availability (HA)
- **Anti-Pod Affinity**: Configured for OpenBao, PostgreSQL, and Istio to ensure components are distributed across nodes.
- **Stateless/Stateful separation**: Clear boundaries between infrastructure and application layers.

### 2. Triple-Layer TLS
- **Gateway TLS**: Secure external access via Istio Ingress.
- **Mesh mTLS**: Strict mTLS between all services in the mesh.
- **Application TLS**: OpenBao serves own HTTPS for internal and external traffic.

### 3. Secure Ansible Workflows
- **SSH CA**: Eliminates static SSH keys; target servers trust OpenBao's CA.
- **JIT Access**: SSH keys are signed only after an approval gate in GitHub Actions.
- **Stored Certs**: Signed certificates are stored in OpenBao and must be "pulled" by an authenticated operator.

## 📖 Documentation

- [Use Cases Guide](docs/use-cases.md): SSH CA, PII Tokenization (Transit), and OpenBao Agent.
- [Integration Guide](docs/integrations.md): How to use this stack with CLI, SemaphoreUI, and AWX.

## ⚙️ How to Deploy

1. **Bootstrap FluxCD**:
   ```bash
   flux bootstrap github --owner=<your-org> --repository=openbao-k8s --path=clusters/production
   ```
2. **Setup Secrets**:
   Create the `openbao-root-token` secret in the `openbao` namespace to allow the automation job to configure the engines.

## 🧪 Local Development

To test this stack locally on a single-node cluster (like `kind`), use the provided setup script. It will create a cluster, install necessary CRDs, and apply patches to relax High Availability constraints (reducing replica counts for a single node).

```bash
./scripts/setup-local-dev.sh
```

### Prerequisites
- [kind](https://kind.sigs.k8s.io/docs/user/quick-start/)
- [kubectl](https://kubernetes.io/docs/tasks/tools/)
- [flux CLI](https://fluxcd.io/flux/installation/)

## 📄 License
MIT
