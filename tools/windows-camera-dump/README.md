# Windows camera dump

Run from an elevated Windows PowerShell when possible:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\collect.ps1 -IncludeRegistry -CopyInfFiles
```

The default output is `camera-dump-windows-<timestamp>` in the current
directory. `-CopyInfFiles` copies only matching files from `C:\Windows\INF`.
It does not export complete DriverStore packages. Vendor `.sys`, `.dll`, and
firmware files are represented by path/version/SHA256 metadata only.

The dump may contain device instance IDs, host information, registry data, and
vendor INF text. Review and redact it before publication.
