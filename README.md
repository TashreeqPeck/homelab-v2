# homelab-v2

Infrastructure as Code for my personal homelab. This repository is the single source of truth for how the lab is defined, provisioned, and kept in a desired state.

## Goals

- **Automate everything practical** — provisioning, configuration, updates, and routine operations should run through code and pipelines rather than manual steps.
- **Learn by doing** — treat the homelab as a sandbox to explore IaC patterns, GitOps, CI/CD, networking, and operations at small scale.
- **Reproducibility** — be able to rebuild or extend the environment from this repo with minimal one-off setup.

Full automation is the target; where that is not yet possible, the gap should be documented and narrowed over time.

## Scope (planned)

This repo is intended to grow to cover things such as:

- Compute and virtualization (hosts, VMs, containers)
- Network and DNS configuration
- Core services (storage, monitoring, identity, backups)
- Deployment and change workflows (e.g. GitOps, CI)

Exact tools and layout will evolve as the lab does. Early commits may be experimental.

## Status

**Early stage** — structure and tooling are not in place yet. Check commit history and directories as they appear for what is actually implemented versus planned.

## License

Private homelab use unless stated otherwise in the repository.
