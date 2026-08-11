# Linux camera dump

```bash
chmod +x collect.sh
./collect.sh --sudo --debug-libcamera
```

The script continues when optional tools or permissions are missing and records
failures in `collection-errors.txt`. `--sudo` uses `sudo -n`, so it will not
block waiting for a password. Run the script from an already-authenticated root
shell if a complete `dmesg` and ACPI dump are required.

The default output is `camera-dump-linux-<timestamp>` in the current directory.
Review host identifiers and ACPI data before publication.
