# platform-lab

Airgapped, STIG-hardened Kubernetes platform built on personal lab hardware.
Status: Week 1 (foundation) complete, tagged v0.1. Next: Week 2 (OS hardening).

## Rebuild time

Measured from scratch on the build host (base image already in the pool):

| Date       | `make down` | `make up` (to Ready node) |
|------------|-------------|---------------------------|
| 2026-11-14 | 2s          | 4m34s                     |
