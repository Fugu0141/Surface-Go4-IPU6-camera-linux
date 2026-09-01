# Baseline

Collected before applying the upstream v4 OV5693 series or the proposed Surface Go 4 ADL-N bridge entry.

The key checks for this stage are:

- the machine is Surface Go 4 / Alder Lake-N IPU6
- the exact kernel and module build are recorded
- Secure Boot/module signing state is recorded
- the OV5693 enumeration is captured (`INT33BE` vs `OVTI5693`)
- current camera discovery and relevant kernel messages are preserved
