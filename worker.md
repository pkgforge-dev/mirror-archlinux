<!-- written by scripts/status-collect on 2026-11-14T14:36:08Z -->
The Worker passes every probe.

Worker: https://ghcr.mirror.archlinux.pkgforge.dev. Each probe is a GET with no redirect followed. A target with `latest` must answer 302 to an https URL, and that signed URL must answer a GET of one byte (`Range: bytes=0-0`), with no credential, with 206 or 200. A target with no `latest` must answer 404. Once per run, the smallest database of a target with `latest` is downloaded through the Worker, redirects followed: it must have the sha256 that `latest` names.

| target | probe | HTTP | expected | signed URL | seconds | result |
| --- | --- | --- | --- | --- | --- | --- |
| aarch64-alarm | db | 302 | 302 | 206 | 0.188183 | ok |
| aarch64-alarm | package | 302 | 302 | 206 | 0.088368 | ok |
| aarch64-aur | db | 302 | 302 | 206 | 0.037982 | ok |
| aarch64-aur | package | 302 | 302 | 206 | 0.064416 | ok |
| aarch64-core | db | 302 | 302 | 206 | 0.050399 | ok |
| aarch64-core | package | 302 | 302 | 206 | 0.150081 | ok |
| aarch64-extra | db | 302 | 302 | 206 | 0.207681 | ok |
| aarch64-extra | package | 302 | 302 | 206 | 0.172563 | ok |
| armv7h-alarm | db | 302 | 302 | 206 | 0.196086 | ok |
| armv7h-alarm | package | 302 | 302 | 206 | 0.169504 | ok |
| armv7h-aur | db | 302 | 302 | 206 | 0.048999 | ok |
| armv7h-aur | package | 302 | 302 | 206 | 0.080999 | ok |
| armv7h-aur | download | 200 | 200 | - | 0.111393 | ok |
| armv7h-core | db | 302 | 302 | 206 | 0.050399 | ok |
| armv7h-core | package | 302 | 302 | 206 | 0.049192 | ok |
| armv7h-extra | db | 302 | 302 | 206 | 0.146352 | ok |
| armv7h-extra | package | 302 | 302 | 206 | 0.159646 | ok |
| loong64-core | db | 302 | 302 | 206 | 0.145966 | ok |
| loong64-core | package | 302 | 302 | 206 | 0.086312 | ok |
| loong64-extra | db | 302 | 302 | 206 | 0.176012 | ok |
| loong64-extra | package | 302 | 302 | 206 | 0.043908 | ok |
| powerpc-base | db | 302 | 302 | 206 | 0.103386 | ok |
| powerpc-base | package | 302 | 302 | 206 | 0.249576 | ok |
| powerpc-base-any | db | 302 | 302 | 206 | 0.106625 | ok |
| powerpc-base-any | package | 302 | 302 | 206 | 0.252808 | ok |
| powerpc64-base | db | 302 | 302 | 206 | 0.096842 | ok |
| powerpc64-base | package | 302 | 302 | 206 | 0.046445 | ok |
| powerpc64-base-any | db | 302 | 302 | 206 | 0.097182 | ok |
| powerpc64-base-any | package | 302 | 302 | 206 | 0.072846 | ok |
| powerpc64le-base | db | 302 | 302 | 206 | 0.109061 | ok |
| powerpc64le-base | package | 302 | 302 | 206 | 0.183380 | ok |
| powerpc64le-base-any | db | 302 | 302 | 206 | 0.133749 | ok |
| powerpc64le-base-any | package | 302 | 302 | 206 | 0.153624 | ok |
| riscv64-core | db | 302 | 302 | 206 | 0.131516 | ok |
| riscv64-core | package | 302 | 302 | 206 | 0.045318 | ok |
| riscv64-extra | db | 302 | 302 | 206 | 0.107318 | ok |
| riscv64-extra | package | 302 | 302 | 206 | 0.053214 | ok |
| x86_64-core | db | 302 | 302 | 206 | 0.105380 | ok |
| x86_64-core | package | 302 | 302 | 206 | 0.153818 | ok |
| x86_64-extra | db | 302 | 302 | 206 | 0.156228 | ok |
| x86_64-extra | package | 302 | 302 | 206 | 0.046637 | ok |
| x86_64-multilib | db | 302 | 302 | 206 | 0.143542 | ok |
| x86_64-multilib | package | 302 | 302 | 206 | 0.051516 | ok |

This issue closes itself when the Worker passes its probes again.
