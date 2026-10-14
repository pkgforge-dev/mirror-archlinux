# The wrapper

`client/pacman-oci` lets pacman read a repository that is stored on an OCI registry. It is one POSIX sh file, version 2. pacman runs it as its `XferCommand`.

```ini
[options]
XferCommand = /usr/local/bin/pacman-oci %o %u

[core]
Server = oci://ghcr.io/pkgforge-dev/mirror-archlinux/$arch/$repo
Include = /etc/pacman.d/mirrorlist
```

pacman runs the `XferCommand` for every file it downloads, from each Server in turn. It moves to the next Server when the command exits non-zero. The wrapper reads an `oci://` Server from the registry. It hands every other URL to curl, so the mirrors after it stay the fallback.

## Calls

| call | does |
| --- | --- |
| `pacman-oci OUTPUT URL` | the `XferCommand` form: the file at URL into OUTPUT |
| `pacman-oci --tag FILENAME` | prints the tag a package file is stored under |
| `pacman-oci --tags` | the same for the filenames on stdin; prints `FILENAME<TAB>TAG` |
| `pacman-oci --json FILE` | the JSON parser alone; prints `POINTER<TAB>VALUE` |
| `pacman-oci --version` | prints `pacman-oci 2` |

| exit status | means |
| --- | --- |
| 0 | the file is at OUTPUT |
| 1 | not here, or a check failed: pacman tries the next Server |
| 2 | usage |
| 3 | the `--json` input is not JSON |

## URL forms

| URL | reads |
| --- | --- |
| `oci://HOST/REPOSITORY/FILE` | the database from tag `latest` |
| `oci://HOST/REPOSITORY:TAG/FILE` | the database from a tag |
| `oci://HOST/REPOSITORY@sha256:HEX/FILE` | the database from one manifest, which must hash to HEX |
| `oci+http://HOST/...` | the same over plain http, for a local test registry only |

A package file (`*.pkg.tar`, `*.pkg.tar.*`) and its `.sig` are always read from the package's own tag, whichever database the URL names. A database signature is read from the manifest of the database pacman took just before it.

The wrapper sorts each request into one kind:

| kind | file | read from |
| --- | --- | --- |
| `pkg` | a package | its own tag, layer `FILE` |
| `pkgsig` | its signature | the package's tag, layer `FILE`; never optional |
| `db` | `<repo>.db`, `<repo>.files` | the tag, digest or `latest` of the URL |
| `dbsig` | `<repo>.db.sig`, `<repo>.files.sig` | the manifest of the database beside OUTPUT, found by its content (`db-HEX` or `files-HEX`) |

## Requirements

The wrapper needs `curl`, `awk`, `sed`, `grep`, `sha256sum`, `mktemp` and `base64`, and the other usual tools of coreutils or busybox. Its `find` must know `-mmin`, as GNU findutils and busybox do. It uses `pacman`, `pacman-conf` and `timeout` when they are there. The test suite runs it under bash with gawk, dash with mawk, and busybox.

pacman runs it with fork and execvp, never through a shell. With `DownloadUser` set, it runs as that user, from a `download-XXXXXX` directory in the sync or cache directory. Without `DownloadUser`, it runs as root, in the sync or cache directory.

## The run store

A run of pacman makes many calls of the wrapper, one per file. The run store lets one call prepare files for the calls that follow.

- The key of a run is the parent's pid and its start time: `<ppid>-<start>`. The start time is field 22 of `/proc/<ppid>/stat`, counted after the last `)`. So a pid that the kernel reuses is another run.
- There is a store only when `/proc/<ppid>/comm` starts with `pacman`. Any other parent gets the single-file path with no store.
- Entries are flat files beside OUTPUT: `.pacman-oci.<key>.<name>`. Each one is made under a `mktemp` name in the same directory, then renamed. A call uses an entry only when it is a regular file of this user and not a symbolic link.
- A ready entry `<file>` passed its size and sha256 check before it got its name. A ready `<file>.sig` made from `%PGPSIG%` is the decoded value, with no other check. Serving an entry is one `mv` to OUTPUT, with no copy and no network.
- Each entry is in OUTPUT's own directory. So `,prefetch`, `,dbprefetch` and `,down.<host>` apply to one run in one directory. The sync directory and the cache directory each have their own.

| entry | means |
| --- | --- |
| `<file>` | a file ready for pacman |
| `,open` | the store of this run is open in this directory; the background remover touches it once a second |
| `,prefetch` | the package prefetch of this run ran here |
| `,dbprefetch` | the database prefetch of this run ran here |
| `,down.<host>` | the host failed once its retries were spent |
| `,absent.<file>` | the database manifest of this run has no layer `<file>` |
| `,index` | `FILE<TAB>SHA256<TAB>SIZE` of each package the prefetch planned |
| `,pacver` | the pacman version, asked once per run |
| `,reaper` | the output of the background remover |
| `tmp.*` | files that are being written |

Three things remove the entries:

1. pacman unlinks every regular file of its `download-XXXXXX` directory when it removes that directory.
2. The call that opens the store starts a background remover. It waits until the pacman run ends, then removes the run's entries.
3. Until the store of its run is open in a directory, each call removes the entries of runs that are gone there. A run is gone when two things are true. Its pid is missing or has another start time. It has no `,open` there that is less than 2 minutes old.

While a run is live, its background remover touches its `,open` once a second. A run in another pid namespace has a pid that this `/proc` cannot show. Its fresh `,open` keeps its entries. When a pid namespace ends, its remover ends with it. The first call there after 2 minutes removes the entries that the run left.

⚠ Entries stay flat in OUTPUT's directory, never in a subdirectory. pacman cannot remove a `download-XXXXXX` directory that holds a subdirectory, and leaves it behind. The private work directory goes there only when `TMPDIR` is not writable, and the wrapper removes it on exit.

## Package prefetch

Under an `XferCommand`, pacman asks for one file at a time. The first package request of a run asks pacman itself for the whole list and fetches it in parallel.

The prefetch runs once per run when all of these are true:

- the run has a store
- the requested file name is printable ASCII and does not start with `,`
- `PACMAN_OCI_PREFETCH` is not `0`
- `PACMAN_OCI_JOBS` is more than 1
- `PACMAN_OCI_NO_DUMMY` is not `1`
- OUTPUT's directory holds no `"`, `\`, tab or newline

### The print run

1. The wrapper reads pacman's arguments from `/proc/<ppid>/cmdline`. It refuses, and does no prefetch, when it cannot read them with certainty:
   - an argument holds a newline
   - an option is not known (getopt also takes abbreviations)
   - a path option (`--config`, `--dbpath`, `--root` and others) is relative
   - a target is read from stdin (`-`)
   - the operation is not a sync (`-S` or `--sync`), or `--print` or `-p` is present
2. It rewrites the arguments. It drops every refresh: `--refresh`, and each `y` of a short group before its first `b` or `r`. It drops `--confirm`, `--noconfirm` and `--print-format`. It keeps everything after `--`.
3. It finds the pacman binary from `/proc/<ppid>/exe`, else from `argv[0]`. The download user cannot read `/proc/<ppid>/exe`.
4. It runs pacman with `--print --print-format '%l<TAB>%h<TAB>%s<TAB>%g' --noconfirm --noprogressbar`, under `timeout 120` when `timeout` exists. `pacman -S --print` takes no lock and needs no root.

Each line names the first Server URL (`%l`), the sha256 (`%h`), the download size (`%s`) and the base64 `%PGPSIG%` (`%g`). A `file://` line is a cached file and is skipped.

`%s` leaves out a `.part` that pacman holds in the cache, so the wrapper adds the size of that `.part` back. It reads the size from the file's metadata (`ls -ln`), as pacman's own `stat()` does. So a `.part` that root left with mode 0600 still counts under `DownloadUser`.

A line is work when all of these are true:

- it starts with `oci://`, `oci+http://`, `https://` or `http://`
- it names a package file, not a `.sig`, and `%s` is a number
- for `https://` or `http://`: `%h` is a valid sha256, and the URL holds no `"`, space or `\`
- for `oci://` or `oci+http://`: the host and the repository are valid

Print mode picks the first provider and never prompts. When the run chooses another provider, the serial pass fetches that one alone.

### Signatures

With `PACMAN_OCI_SIG=auto` (the default), the prefetch writes `<file>.sig` from `%g`, decoded, with no request. pacman checks the package against `%PGPSIG%` anyway. When `%g` is empty, the signature of an `oci://` line comes from the registry's layer. The prefetch fetches no `.sig` for an `http://` line. The single-file path then reads `<url>.sig`.

With `PACMAN_OCI_SIG=registry`, the signature of an `oci://` line always comes from the registry's layer. Verify uses this mode, so it checks the stored layers.

### Blob addresses

With `auto`, a valid `%h` and a valid `%g`, the prefetch reads `<base>/blobs/sha256:<h>` directly, with no manifest request. Otherwise it reads the package manifest by its tag, then the layers `FILE` and `FILE.sig`. A layer whose digest is not `%h` is not used.

### Transfers

One curl process runs each list with `--parallel --parallel-max $PACMAN_OCI_JOBS` and a generated `--config` file. Each transfer has its own block with its URL, output, headers and `--max-filesize`. There are at most two phases: the manifests, when any are needed, then the blobs.

- Each finished transfer is checked by size and sha256, then renamed to its ready entry. A file that fails the check is removed.
- A transfer that is cut goes on in the next pass. Cut means: its time limit, 408, 429, 5xx, or a connection that broke after the answer started. With bytes on disk, it resumes with `--continue-at -`. Each pass is a new curl process, so it has new connections.
- A transfer with no answer at all, another 4xx, or a file over its size is not tried again in the prefetch.
- A resumed file that fails its sha256 check starts again from zero, once.
- A pass after the first that makes no file ready and moves less than 30 KiB is the last. There are at most 100 passes.
- Each transfer of pass N gets 3 s times N plus 1 s per MiB, at most 30 s. A file that needs longer goes on in the next pass. So a slow connection costs at most 30 s.

⭐ The prefetch never fails a call. Any file that it did not make ready goes through the single-file path.

On a terminal, or with `PACMAN_OCI_DEBUG=1`, the prefetch prints one line: the file count, the MiB and the seconds. It prints nothing when it made no file ready.

## Database prefetch

The first `oci://` request for a `.db` or `.files` file of a run does the same for databases, once. It reads only the extension that pacman asked for.

1. It reads `--config` from pacman's arguments (default `/etc/pacman.conf`). It does nothing with `--sysroot` or `--arch`, or without `pacman-conf`.
2. It lists the repositories with `pacman-conf --config C --repo-list`, and the first Server of each with `pacman-conf --config C --repo R Server`.
3. For each first Server that is `oci://` or `oci+http://`, it reads the manifests in parallel.
4. A manifest asked for by digest must hash to that digest. A manifest with more than one signature layer is not used.
5. It reads each database blob in parallel, except when the copy pacman holds already has that sha256. pacman downloads every database again on each `-Sy` under an `XferCommand`.
6. A manifest with a signature layer gives its `.sig` too. When a database is ready and its manifest has no signature layer, the wrapper writes an `,absent` entry. The request for that `.sig` then gets the answer for an absent database signature (below), with no network.

## The single-file path

A file the store does not hold is read alone.

1. A host with a `,down.<host>` entry misses at once, for a `pkg` or `db` request. A `.sig` request is never skipped: pacman asks for a `.sig` only from the server that served its file.
2. A URL that is not `oci://` goes to curl (below).
3. The wrapper reads the manifest. It sends `Authorization: Bearer QQ==`, which GHCR accepts for public packages, and saves a token round trip.
4. A 401 or 403 makes it read the Bearer challenge and fetch the anonymous pull token once. Manifest and token requests follow no redirect.
5. A 303 is asked again once, after 1 s. GHCR answers a reference it cannot parse with 303 to an HTML page.
6. A manifest asked for by digest must hash to that digest.
7. Exactly one layer must carry the file's name. A package manifest with no signature layer is an error: pacman tries no other server for a `.sig`.
8. A database signature must sit beside the very database pacman holds. Its manifest is found by the database's content: `db-HEX` for a `.db.sig`, `files-HEX` for a `.files.sig`. When that tag is missing, the URL's own manifest is used only when it names that database. With no database beside OUTPUT, the URL's own manifest is used.
9. A file that pacman already holds with the right size and sha256 is copied to OUTPUT, with no download.
10. The blob is read in up to 3 attempts. The blob's size and sha256 must equal the layer's descriptor.

### Resume

A blob download keeps OUTPUT between attempts and resumes with `--continue-at -`. A resumed file that fails the sha256 check is removed and fetched once more from zero.

An attempt is tried again after HTTP 408, 429 or 5xx. It is also tried again after curl exits 6, 16, 18, 28, 35, 52, 55, 56 or 92. These are a name, TLS, HTTP/2 or time failure, an empty answer, or a cut transfer. After curl exit 33 (a range the server refuses), OUTPUT is removed, and the attempts after it start from zero. Any other failure misses at once. The waits between attempts are 1 s, then 2 s.

When the size of the file is known and the file can resume, each attempt has a time limit:

| attempt | time limit |
| --- | --- |
| 1 | 3 s plus 1 s per MiB |
| 2 | 30 s plus 1 s per 128 KiB |
| 3 | none |

An attempt that cannot resume has no time limit, because a cut would lose all its bytes. That is an attempt after a refused range, and the fetch from zero after a resumed file failed its sha256 check.

No attempt starts after 30 s, unless the one before it added bytes. A refused range starts these 30 s again.

### Plain URLs

pacman's own downloader is off when an `XferCommand` is set. So the wrapper also fetches the fallback mirrors, with curl. A package resumes what it got. When the prefetch of the run planned the package, its `,index` line bounds the size, and a resumed file must have its sha256.

### The host blacklist

A `pkg` or `db` request that ends with no answer (HTTP 000), 429 or 5xx, once its own retries are spent, writes `,down.<host>`. Later `pkg` and `db` requests of the same run, in the same directory, to that host miss at once. pacman then tries the next Server with no wait for timeouts.

A signature request never writes `,down.<host>`. pacman ignores a failed optional signature, then asks the same host for the next file. A failed required signature stops the transaction anyway. pacman's own downloader also never counts an optional request against a server.

### An absent database signature

⚠ pacman sleeps 2 s after every download that fails, also for an optional signature. No upstream of this mirror publishes a database signature, so each repository costs 2 s on every `-Sy`.

Under the sandbox, OUTPUT is in a `download-XXXXXX` directory. pacman 7.0 and 7.1 unlink a zero-byte file there, and then read the signature as missing (libalpm `dload.c` `finalize_download_file`). So when the manifest has no signature layer, the wrapper writes an empty OUTPUT and exits 0. There is then no pause.

The wrapper does this only when all of these are true:

- the file is a database signature
- OUTPUT is in a `download-XXXXXX` directory
- the parent pacman says it is version 7.0 or 7.1
- `PACMAN_OCI_EMPTY_SIG` is not `0`

With no sandbox, the empty file would stay as the signature. So the wrapper misses there, and pacman pauses. Set `SigLevel = Required DatabaseNever` in each `oci://` repository section to remove the request.

### Deadlines

| request | limits |
| --- | --- |
| manifest, token, single-file path | `--connect-timeout 10 --max-time 15`, `--retry 2 --retry-max-time 30`, 64 KiB at most |
| manifest, prefetch | `--connect-timeout 10 --max-time 15`, 64 KiB at most, no retry |
| blob, single-file path | `--connect-timeout 20 --speed-limit 1024 --speed-time 60`, plus the attempt limits above |
| prefetch transfer | `--connect-timeout 10 --speed-limit 1024 --speed-time 60`, plus the pass limit above |
| print run | `timeout 120` |

A manifest far larger than any real one fails at once. The parser is plain awk.

## Environment

| variable | default | effect |
| --- | --- | --- |
| `PACMAN_OCI_DEBUG` | `0` | `1` prints each request and decision to stderr |
| `PACMAN_OCI_PREFETCH` | `1` | `0` turns the prefetch off: each file is one request |
| `PACMAN_OCI_JOBS` | `32` | transfers at once in a prefetch, at most 64; `1`, or a value that is not a number, turns the prefetch off |
| `PACMAN_OCI_SIG` | `auto` | `registry` reads each package signature from the registry's layer, never from `%PGPSIG%` |
| `PACMAN_OCI_NO_DUMMY` | `0` | `1` skips `Bearer QQ==` and uses the registry's token flow, with no prefetch; the watchdog uses it |
| `PACMAN_OCI_EMPTY_SIG` | `1` | `0` turns off the empty answer for an absent database signature |
| `PACMAN_OCI_TEST_PROC` | unset | for the test suite only: read the parent from DIR, not `/proc`; used only when DIR holds a file named `pacman-oci-test-proc` |
| `TMPDIR` | `/tmp` | where the private work directory goes; OUTPUT's directory when TMPDIR is not writable |

## Security of the store

- The wrapper serves no package or database that a call did not check. A ready entry passed its size and sha256 check, against `%SHA256SUM%` or the layer descriptor, before it got its name. A `.sig` entry made from `%PGPSIG%` is the value that pacman checks the package against.
- An entry is used only when it is a regular file owned by the user that runs the wrapper, and not a symbolic link.
- Under `DownloadUser`, the store sits in the `download-XXXXXX` directory, mode 0700, owned by the download user. pacman removes that directory with the run.
- Without `DownloadUser`, the store sits in the sync or cache directory, which root owns. The wrapper runs as root there.
- A store lasts one run of pacman. There is no cache across runs. A package tag can be pushed again to repair its signature layer. So a cache keyed by tag could serve a stale `.sig`. pacman's own `CacheDir` keeps packages across runs.
- A filename never reaches a shell as code. sed and awk read it as data, on stdin or through the environment. On the `oci://` path, the wrapper refuses a name that makepkg could never make. That is an empty name, `.`, `..`, or a name with a space, a control character or a byte above 0x7e.
- The test hook `PACMAN_OCI_TEST_PROC` works only with its marker file, so it cannot trigger by accident.
