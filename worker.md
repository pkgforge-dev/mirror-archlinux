<!-- written by scripts/status-collect on 2026-10-17T19:37:22Z -->
The Worker passes every probe.

Worker: https://ghcr.mirror.archlinux.pkgforge.dev. Each probe is a GET with no redirect followed. A target with `latest` must answer 302 to an https URL, and that signed URL must answer a GET of one byte (`Range: bytes=0-0`), with no credential, with 206 or 200. A target with no `latest` must answer 404. Once per run, the smallest database of a target with `latest` is downloaded through the Worker, redirects followed: it must have the sha256 that `latest` names.

| target | probe | HTTP | expected | signed URL | seconds | result |
| --- | --- | --- | --- | --- | --- | --- |
| aarch64-alarm | db | 302 | 302 | 206 | 0.163362 | ok |
| aarch64-alarm | package | 302 | 302 | 206 | 0.205183 | ok |
| aarch64-aur | db | 302 | 302 | 206 | 0.180620 | ok |
| aarch64-aur | package | 302 | 302 | 206 | 0.128164 | ok |
| aarch64-core | db | 302 | 302 | 206 | 0.062578 | ok |
| aarch64-core | package | 302 | 302 | 206 | 0.406992 | ok |
| aarch64-extra | db | 302 | 302 | 206 | 0.075963 | ok |
| aarch64-extra | package | 302 | 302 | 206 | 0.143457 | ok |
| armv7h-alarm | db | 302 | 302 | 206 | 0.187769 | ok |
| armv7h-alarm | package | 302 | 302 | 206 | 0.146195 | ok |
| armv7h-aur | db | 302 | 302 | 206 | 0.225642 | ok |
| armv7h-aur | package | 302 | 302 | 206 | 0.111857 | ok |
| armv7h-aur | download | 200 | 200 | - | 0.154029 | ok |
| armv7h-core | db | 302 | 302 | 206 | 0.372363 | ok |
| armv7h-core | package | 302 | 302 | 206 | 0.118433 | ok |
| armv7h-extra | db | 302 | 302 | 206 | 0.165743 | ok |
| armv7h-extra | package | 302 | 302 | 206 | 0.121032 | ok |
| loong64-core | db | 302 | 302 | 206 | 0.158281 | ok |
| loong64-core | package | 302 | 302 | 206 | 0.149548 | ok |
| loong64-extra | db | 302 | 302 | 206 | 0.154278 | ok |
| loong64-extra | package | 302 | 302 | 206 | 0.168296 | ok |
| powerpc-base | db | 302 | 302 | 206 | 0.196901 | ok |
| powerpc-base | package | 302 | 302 | 206 | 0.173157 | ok |
| powerpc-base-any | db | 302 | 302 | 206 | 0.175913 | ok |
| powerpc-base-any | package | 302 | 302 | 206 | 0.359497 | ok |
| powerpc64-base | db | 302 | 302 | 206 | 0.161692 | ok |
| powerpc64-base | package | 302 | 302 | 206 | 0.111565 | ok |
| powerpc64-base-any | db | 302 | 302 | 206 | 0.159292 | ok |
| powerpc64-base-any | package | 302 | 302 | 206 | 0.150317 | ok |
| powerpc64le-base | db | 302 | 302 | 206 | 0.168886 | ok |
| powerpc64le-base | package | 302 | 302 | 206 | 0.116412 | ok |
| powerpc64le-base-any | db | 302 | 302 | 206 | 0.190823 | ok |
| powerpc64le-base-any | package | 302 | 302 | 206 | 0.177032 | ok |
| riscv64-core | db | 302 | 302 | 206 | 0.218415 | ok |
| riscv64-core | package | 302 | 302 | 206 | 0.144943 | ok |
| riscv64-extra | db | 302 | 302 | 206 | 0.217473 | ok |
| riscv64-extra | package | 302 | 302 | 206 | 0.102401 | ok |
| x86_64-core | db | 302 | 302 | 206 | 0.188402 | ok |
| x86_64-core | package | 302 | 302 | 206 | 0.114075 | ok |
| x86_64-extra | db | 302 | 302 | 206 | 0.195123 | ok |
| x86_64-extra | package | 302 | 302 | 206 | 0.258120 | ok |
| x86_64-multilib | db | 302 | 302 | 206 | 0.160454 | ok |
| x86_64-multilib | package | 302 | 302 | 206 | 0.137306 | ok |

This issue closes itself when the Worker passes its probes again.
