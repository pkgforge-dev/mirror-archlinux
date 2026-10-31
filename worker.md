<!-- written by scripts/status-collect on 2026-10-31T18:53:08Z -->
The Worker passes every probe.

Worker: https://ghcr.mirror.archlinux.pkgforge.dev. Each probe is a GET with no redirect followed. A target with `latest` must answer 302 to an https URL, and that signed URL must answer a GET of one byte (`Range: bytes=0-0`), with no credential, with 206 or 200. A target with no `latest` must answer 404. Once per run, the smallest database of a target with `latest` is downloaded through the Worker, redirects followed: it must have the sha256 that `latest` names.

| target | probe | HTTP | expected | signed URL | seconds | result |
| --- | --- | --- | --- | --- | --- | --- |
| aarch64-alarm | db | 302 | 302 | 206 | 0.226946 | ok |
| aarch64-alarm | package | 302 | 302 | 206 | 0.192059 | ok |
| aarch64-aur | db | 302 | 302 | 206 | 0.197488 | ok |
| aarch64-aur | package | 302 | 302 | 206 | 0.203787 | ok |
| aarch64-core | db | 302 | 302 | 206 | 0.146073 | ok |
| aarch64-core | package | 302 | 302 | 206 | 0.159555 | ok |
| aarch64-extra | db | 302 | 302 | 206 | 0.192460 | ok |
| aarch64-extra | package | 302 | 302 | 206 | 0.116465 | ok |
| armv7h-alarm | db | 302 | 302 | 206 | 0.186072 | ok |
| armv7h-alarm | package | 302 | 302 | 206 | 0.107171 | ok |
| armv7h-aur | db | 302 | 302 | 206 | 0.184222 | ok |
| armv7h-aur | package | 302 | 302 | 206 | 0.212023 | ok |
| armv7h-aur | download | 200 | 200 | - | 0.198446 | ok |
| armv7h-core | db | 302 | 302 | 206 | 0.207911 | ok |
| armv7h-core | package | 302 | 302 | 206 | 0.097782 | ok |
| armv7h-extra | db | 302 | 302 | 206 | 0.175303 | ok |
| armv7h-extra | package | 302 | 302 | 206 | 0.088979 | ok |
| loong64-core | db | 302 | 302 | 206 | 0.214545 | ok |
| loong64-core | package | 302 | 302 | 206 | 0.146528 | ok |
| loong64-extra | db | 302 | 302 | 206 | 0.165730 | ok |
| loong64-extra | package | 302 | 302 | 206 | 0.133505 | ok |
| powerpc-base | db | 302 | 302 | 206 | 0.167739 | ok |
| powerpc-base | package | 302 | 302 | 206 | 0.110607 | ok |
| powerpc-base-any | db | 302 | 302 | 206 | 0.197618 | ok |
| powerpc-base-any | package | 302 | 302 | 206 | 0.125930 | ok |
| powerpc64-base | db | 302 | 302 | 206 | 0.161128 | ok |
| powerpc64-base | package | 302 | 302 | 206 | 0.118299 | ok |
| powerpc64-base-any | db | 302 | 302 | 206 | 0.185643 | ok |
| powerpc64-base-any | package | 302 | 302 | 206 | 0.118243 | ok |
| powerpc64le-base | db | 302 | 302 | 206 | 0.203503 | ok |
| powerpc64le-base | package | 302 | 302 | 206 | 0.121552 | ok |
| powerpc64le-base-any | db | 302 | 302 | 206 | 0.151734 | ok |
| powerpc64le-base-any | package | 302 | 302 | 206 | 0.130597 | ok |
| riscv64-core | db | 302 | 302 | 206 | 0.132993 | ok |
| riscv64-core | package | 302 | 302 | 206 | 0.135997 | ok |
| riscv64-extra | db | 302 | 302 | 206 | 0.122016 | ok |
| riscv64-extra | package | 302 | 302 | 206 | 0.115762 | ok |
| x86_64-core | db | 302 | 302 | 206 | 0.131049 | ok |
| x86_64-core | package | 302 | 302 | 206 | 0.128362 | ok |
| x86_64-extra | db | 302 | 302 | 206 | 0.097637 | ok |
| x86_64-extra | package | 302 | 302 | 206 | 0.119566 | ok |
| x86_64-multilib | db | 302 | 302 | 206 | 0.166035 | ok |
| x86_64-multilib | package | 302 | 302 | 206 | 0.139439 | ok |

This issue closes itself when the Worker passes its probes again.
