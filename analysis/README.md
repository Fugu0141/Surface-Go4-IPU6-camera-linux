# Camera dump workspace

This tree is intentionally empty in Git. The collectors write outside the
repository by default; pass an explicit output path under `analysis/windows/`
or `analysis/linux/` only when preparing a sanitized, reviewable fixture.

- `windows/`: Windows reference observations.
- `linux/`: Linux observations.
- `reports/`: generated comparisons.

Raw dumps can contain machine names, device instance IDs, serial-like values,
registry data, firmware paths, and vendor INF files. Review and redact them
before sharing. Do not add `.sys`, `.dll`, firmware, or other vendor binaries.
