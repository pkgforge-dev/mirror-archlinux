<!-- written by scripts/status-collect on 2026-11-21T11:08:09Z -->
The Worker passes every probe.

Worker: https://ghcr.mirror.archlinux.pkgforge.dev. Each probe is a GET with no redirect followed. A target with `latest` must answer 302 to an https URL, and that signed URL must answer a GET of one byte (`Range: bytes=0-0`), with no credential, with 206 or 200. A target with no `latest` must answer 404. Once per run, the smallest database of a target with `latest` is downloaded through the Worker, redirects followed: it must have the sha256 that `latest` names.

| target | probe | HTTP | expected | signed URL | seconds | result |
| --- | --- | --- | --- | --- | --- | --- |
| aarch64-alarm | db | 302 | 302 | 206 | 0.207155 | ok |
| aarch64-alarm | package | 302 | 302 | 206 | 0.128254 | ok |
| aarch64-aur | db | 302 | 302 | 206 | 0.157069 | ok |
| aarch64-aur | package | 302 | 302 | 206 | 0.105314 | ok |
| aarch64-core | db | 302 | 302 | 206 | 0.162737 | ok |
| aarch64-core | package | 302 | 302 | 206 | 0.100810 | ok |
| aarch64-extra | db | 302 | 302 | 206 | 0.186012 | ok |
| aarch64-extra | package | 302 | 302 | 206 | 0.136723 | ok |
| armv7h-alarm | db | 302 | 302 | 206 | 0.191923 | ok |
| armv7h-alarm | package | 302 | 302 | 206 | 7.281926 | ok |
| armv7h-aur | db | 302 | 302 | 206 | 0.203678 | ok |
| armv7h-aur | package | 302 | 302 | 206 | 0.140773 | ok |
| armv7h-aur | download | 200 | 200 | - | 0.150954 | ok |
| armv7h-core | db | 302 | 302 | 206 | 0.160284 | ok |
| armv7h-core | package | 302 | 302 | 206 | 0.152368 | ok |
| armv7h-extra | db | 302 | 302 | 206 | 0.183378 | ok |
| armv7h-extra | package | 302 | 302 | 206 | 0.149306 | ok |
| loong64-core | db | 302 | 302 | 206 | 0.180491 | ok |
| loong64-core | package | 302 | 302 | 206 | 0.110478 | ok |
| loong64-extra | db | 302 | 302 | 206 | 0.153180 | ok |
| loong64-extra | package | 302 | 302 | 206 | 0.112748 | ok |
| powerpc-base | db | 302 | 302 | 206 | 1.205611 | ok |
| powerpc-base | package | 302 | 302 | 206 | 0.120677 | ok |
| powerpc-base-any | db | 302 | 302 | 206 | 0.171295 | ok |
| powerpc-base-any | package | 302 | 302 | 206 | 0.104565 | ok |
| powerpc64-base | db | 302 | 302 | 206 | 0.173639 | ok |
| powerpc64-base | package | 302 | 302 | 206 | 0.103236 | ok |
| powerpc64-base-any | db | 302 | 302 | 206 | 0.137289 | ok |
| powerpc64-base-any | package | 302 | 302 | 206 | 0.117659 | ok |
| powerpc64le-base | db | 302 | 302 | 206 | 0.216369 | ok |
| powerpc64le-base | package | 302 | 302 | 206 | 0.108767 | ok |
| powerpc64le-base-any | db | 302 | 302 | 206 | 0.177853 | ok |
| powerpc64le-base-any | package | 302 | 302 | 206 | 0.116388 | ok |
| riscv64-core | db | 302 | 302 | 206 | 0.202235 | ok |
| riscv64-core | package | 302 | 302 | 206 | 0.105788 | ok |
| riscv64-extra | db | 302 | 302 | 206 | 0.171936 | ok |
| riscv64-extra | package | 302 | 302 | 206 | 0.097843 | ok |
| x86_64-core | db | 302 | 302 | 206 | 0.173898 | ok |
| x86_64-core | package | 302 | 302 | 206 | 0.121135 | ok |
| x86_64-extra | db | 302 | 302 | 206 | 0.142167 | ok |
| x86_64-extra | package | 302 | 302 | 206 | 0.131439 | ok |
| x86_64-multilib | db | 302 | 302 | 206 | 0.143916 | ok |
| x86_64-multilib | package | 302 | 302 | 206 | 0.134645 | ok |

This issue closes itself when the Worker passes its probes again.
