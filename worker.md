<!-- written by scripts/status-collect on 2026-10-24T14:07:44Z -->
The Worker passes every probe.

Worker: https://ghcr.mirror.archlinux.pkgforge.dev. Each probe is a GET with no redirect followed. A target with `latest` must answer 302 to an https URL, and that signed URL must answer a GET of one byte (`Range: bytes=0-0`), with no credential, with 206 or 200. A target with no `latest` must answer 404. Once per run, the smallest database of a target with `latest` is downloaded through the Worker, redirects followed: it must have the sha256 that `latest` names.

| target | probe | HTTP | expected | signed URL | seconds | result |
| --- | --- | --- | --- | --- | --- | --- |
| aarch64-alarm | db | 302 | 302 | 206 | 0.198346 | ok |
| aarch64-alarm | package | 302 | 302 | 206 | 0.138582 | ok |
| aarch64-aur | db | 302 | 302 | 206 | 0.199958 | ok |
| aarch64-aur | package | 302 | 302 | 206 | 0.151110 | ok |
| aarch64-core | db | 302 | 302 | 206 | 0.180791 | ok |
| aarch64-core | package | 302 | 302 | 206 | 0.104718 | ok |
| aarch64-extra | db | 302 | 302 | 206 | 0.200171 | ok |
| aarch64-extra | package | 302 | 302 | 206 | 0.117712 | ok |
| armv7h-alarm | db | 302 | 302 | 206 | 0.174448 | ok |
| armv7h-alarm | package | 302 | 302 | 206 | 0.111669 | ok |
| armv7h-aur | db | 302 | 302 | 206 | 0.161200 | ok |
| armv7h-aur | package | 302 | 302 | 206 | 0.219923 | ok |
| armv7h-aur | download | 200 | 200 | - | 0.152090 | ok |
| armv7h-core | db | 302 | 302 | 206 | 0.165544 | ok |
| armv7h-core | package | 302 | 302 | 206 | 0.107243 | ok |
| armv7h-extra | db | 302 | 302 | 206 | 0.137670 | ok |
| armv7h-extra | package | 302 | 302 | 206 | 0.136066 | ok |
| loong64-core | db | 302 | 302 | 206 | 0.160910 | ok |
| loong64-core | package | 302 | 302 | 206 | 0.118318 | ok |
| loong64-extra | db | 302 | 302 | 206 | 0.156507 | ok |
| loong64-extra | package | 302 | 302 | 206 | 0.117754 | ok |
| powerpc-base | db | 302 | 302 | 206 | 0.146981 | ok |
| powerpc-base | package | 302 | 302 | 206 | 0.288151 | ok |
| powerpc-base-any | db | 302 | 302 | 206 | 0.199174 | ok |
| powerpc-base-any | package | 302 | 302 | 206 | 0.177946 | ok |
| powerpc64-base | db | 302 | 302 | 206 | 0.190178 | ok |
| powerpc64-base | package | 302 | 302 | 206 | 0.181005 | ok |
| powerpc64-base-any | db | 302 | 302 | 206 | 0.210616 | ok |
| powerpc64-base-any | package | 302 | 302 | 206 | 0.179650 | ok |
| powerpc64le-base | db | 302 | 302 | 206 | 0.149664 | ok |
| powerpc64le-base | package | 302 | 302 | 206 | 0.177569 | ok |
| powerpc64le-base-any | db | 302 | 302 | 206 | 0.146408 | ok |
| powerpc64le-base-any | package | 302 | 302 | 206 | 0.194563 | ok |
| riscv64-core | db | 302 | 302 | 206 | 0.264287 | ok |
| riscv64-core | package | 302 | 302 | 206 | 0.142623 | ok |
| riscv64-extra | db | 302 | 302 | 206 | 0.246325 | ok |
| riscv64-extra | package | 302 | 302 | 206 | 0.111335 | ok |
| x86_64-core | db | 302 | 302 | 206 | 0.125727 | ok |
| x86_64-core | package | 302 | 302 | 206 | 0.099052 | ok |
| x86_64-extra | db | 302 | 302 | 206 | 0.228007 | ok |
| x86_64-extra | package | 302 | 302 | 206 | 0.123660 | ok |
| x86_64-multilib | db | 302 | 302 | 206 | 0.204322 | ok |
| x86_64-multilib | package | 302 | 302 | 206 | 0.101252 | ok |

This issue closes itself when the Worker passes its probes again.
