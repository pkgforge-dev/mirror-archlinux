<!-- written by scripts/status-collect on 2026-11-07T20:18:14Z -->
The Worker passes every probe.

Worker: https://ghcr.mirror.archlinux.pkgforge.dev. Each probe is a GET with no redirect followed. A target with `latest` must answer 302 to an https URL, and that signed URL must answer a GET of one byte (`Range: bytes=0-0`), with no credential, with 206 or 200. A target with no `latest` must answer 404. Once per run, the smallest database of a target with `latest` is downloaded through the Worker, redirects followed: it must have the sha256 that `latest` names.

| target | probe | HTTP | expected | signed URL | seconds | result |
| --- | --- | --- | --- | --- | --- | --- |
| aarch64-alarm | db | 302 | 302 | 206 | 0.459362 | ok |
| aarch64-alarm | package | 302 | 302 | 206 | 0.277728 | ok |
| aarch64-aur | db | 302 | 302 | 206 | 0.357826 | ok |
| aarch64-aur | package | 302 | 302 | 206 | 0.391160 | ok |
| aarch64-core | db | 302 | 302 | 206 | 0.350302 | ok |
| aarch64-core | package | 302 | 302 | 206 | 0.222742 | ok |
| aarch64-extra | db | 302 | 302 | 206 | 0.338166 | ok |
| aarch64-extra | package | 302 | 302 | 206 | 0.211865 | ok |
| armv7h-alarm | db | 302 | 302 | 206 | 0.320348 | ok |
| armv7h-alarm | package | 302 | 302 | 206 | 0.175112 | ok |
| armv7h-aur | db | 302 | 302 | 206 | 0.294626 | ok |
| armv7h-aur | package | 302 | 302 | 206 | 0.185131 | ok |
| armv7h-aur | download | 200 | 200 | - | 0.228189 | ok |
| armv7h-core | db | 302 | 302 | 206 | 0.297451 | ok |
| armv7h-core | package | 302 | 302 | 206 | 0.176862 | ok |
| armv7h-extra | db | 302 | 302 | 206 | 0.517458 | ok |
| armv7h-extra | package | 302 | 302 | 206 | 0.207964 | ok |
| loong64-core | db | 302 | 302 | 206 | 0.319409 | ok |
| loong64-core | package | 302 | 302 | 206 | 0.180567 | ok |
| loong64-extra | db | 302 | 302 | 206 | 0.295952 | ok |
| loong64-extra | package | 302 | 302 | 206 | 0.253221 | ok |
| powerpc-base | db | 302 | 302 | 206 | 0.293686 | ok |
| powerpc-base | package | 302 | 302 | 206 | 0.300145 | ok |
| powerpc-base-any | db | 302 | 302 | 206 | 0.305494 | ok |
| powerpc-base-any | package | 302 | 302 | 206 | 0.292196 | ok |
| powerpc64-base | db | 302 | 302 | 206 | 0.275076 | ok |
| powerpc64-base | package | 302 | 302 | 206 | 0.304163 | ok |
| powerpc64-base-any | db | 302 | 302 | 206 | 0.332356 | ok |
| powerpc64-base-any | package | 302 | 302 | 206 | 0.339805 | ok |
| powerpc64le-base | db | 302 | 302 | 206 | 0.288724 | ok |
| powerpc64le-base | package | 302 | 302 | 206 | 0.283276 | ok |
| powerpc64le-base-any | db | 302 | 302 | 206 | 0.327686 | ok |
| powerpc64le-base-any | package | 302 | 302 | 206 | 0.297342 | ok |
| riscv64-core | db | 302 | 302 | 206 | 0.298656 | ok |
| riscv64-core | package | 302 | 302 | 206 | 0.181842 | ok |
| riscv64-extra | db | 302 | 302 | 206 | 0.291059 | ok |
| riscv64-extra | package | 302 | 302 | 206 | 0.162924 | ok |
| x86_64-core | db | 302 | 302 | 206 | 0.297367 | ok |
| x86_64-core | package | 302 | 302 | 206 | 0.180570 | ok |
| x86_64-extra | db | 302 | 302 | 206 | 0.306052 | ok |
| x86_64-extra | package | 302 | 302 | 206 | 0.251009 | ok |
| x86_64-multilib | db | 302 | 302 | 206 | 0.280216 | ok |
| x86_64-multilib | package | 302 | 302 | 206 | 0.191389 | ok |

This issue closes itself when the Worker passes its probes again.
