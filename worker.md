<!-- written by scripts/status-collect on 2026-11-28T16:58:42Z -->
The Worker passes every probe.

Worker: https://ghcr.mirror.archlinux.pkgforge.dev. Each probe is a GET with no redirect followed. A target with `latest` must answer 302 to an https URL, and that signed URL must answer a GET of one byte (`Range: bytes=0-0`), with no credential, with 206 or 200. A target with no `latest` must answer 404. Once per run, the smallest database of a target with `latest` is downloaded through the Worker, redirects followed: it must have the sha256 that `latest` names.

| target | probe | HTTP | expected | signed URL | seconds | result |
| --- | --- | --- | --- | --- | --- | --- |
| aarch64-alarm | db | 302 | 302 | 206 | 0.233542 | ok |
| aarch64-alarm | package | 302 | 302 | 206 | 0.147763 | ok |
| aarch64-aur | db | 302 | 302 | 206 | 0.213303 | ok |
| aarch64-aur | package | 302 | 302 | 206 | 0.125035 | ok |
| aarch64-core | db | 302 | 302 | 206 | 0.246079 | ok |
| aarch64-core | package | 302 | 302 | 206 | 0.160894 | ok |
| aarch64-extra | db | 302 | 302 | 206 | 0.173815 | ok |
| aarch64-extra | package | 302 | 302 | 206 | 0.199961 | ok |
| armv7h-alarm | db | 302 | 302 | 206 | 0.163715 | ok |
| armv7h-alarm | package | 302 | 302 | 206 | 0.162570 | ok |
| armv7h-aur | db | 302 | 302 | 206 | 0.190218 | ok |
| armv7h-aur | package | 302 | 302 | 206 | 0.153313 | ok |
| armv7h-aur | download | 200 | 200 | - | 0.127328 | ok |
| armv7h-core | db | 302 | 302 | 206 | 0.194773 | ok |
| armv7h-core | package | 302 | 302 | 206 | 0.127358 | ok |
| armv7h-extra | db | 302 | 302 | 206 | 0.165661 | ok |
| armv7h-extra | package | 302 | 302 | 206 | 0.114261 | ok |
| loong64-core | db | 302 | 302 | 206 | 0.182505 | ok |
| loong64-core | package | 302 | 302 | 206 | 0.135990 | ok |
| loong64-extra | db | 302 | 302 | 206 | 0.221084 | ok |
| loong64-extra | package | 302 | 302 | 206 | 0.175148 | ok |
| powerpc-base | db | 302 | 302 | 206 | 0.227115 | ok |
| powerpc-base | package | 302 | 302 | 206 | 0.121369 | ok |
| powerpc-base-any | db | 302 | 302 | 206 | 0.145456 | ok |
| powerpc-base-any | package | 302 | 302 | 206 | 0.213970 | ok |
| powerpc64-base | db | 302 | 302 | 206 | 0.180602 | ok |
| powerpc64-base | package | 302 | 302 | 206 | 0.122827 | ok |
| powerpc64-base-any | db | 302 | 302 | 206 | 0.157298 | ok |
| powerpc64-base-any | package | 302 | 302 | 206 | 0.112935 | ok |
| powerpc64le-base | db | 302 | 302 | 206 | 0.164083 | ok |
| powerpc64le-base | package | 302 | 302 | 206 | 0.112883 | ok |
| powerpc64le-base-any | db | 302 | 302 | 206 | 0.173348 | ok |
| powerpc64le-base-any | package | 302 | 302 | 206 | 0.120973 | ok |
| riscv64-core | db | 302 | 302 | 206 | 0.168789 | ok |
| riscv64-core | package | 302 | 302 | 206 | 0.125526 | ok |
| riscv64-extra | db | 302 | 302 | 206 | 0.214112 | ok |
| riscv64-extra | package | 302 | 302 | 206 | 0.116559 | ok |
| x86_64-core | db | 302 | 302 | 206 | 0.220189 | ok |
| x86_64-core | package | 302 | 302 | 206 | 0.143092 | ok |
| x86_64-extra | db | 302 | 302 | 206 | 0.175730 | ok |
| x86_64-extra | package | 302 | 302 | 206 | 0.159620 | ok |
| x86_64-multilib | db | 302 | 302 | 206 | 0.156257 | ok |
| x86_64-multilib | package | 302 | 302 | 206 | 0.124225 | ok |

This issue closes itself when the Worker passes its probes again.
