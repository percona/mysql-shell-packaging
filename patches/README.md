# Percona patches for MySQL Shell

Everything else in this repository builds **unmodified upstream** sources. This
directory holds the one exception: the Percona feature/bugfix patches applied on
top of upstream MySQL Shell before packaging.

## Layout

```
sources.conf                 where each shell series' patches come from
refresh.sh                   regenerate a series from its source
<series>/series              ordered list of patches to apply
<series>/NNNN-*.patch        one file per upstream commit
<series>/PROVENANCE          source URL, fetch time, per-patch sha256
```

`<series>` is the shell major.minor, e.g. `9.7`. A build of `9.7.1` uses
`9.7/`; a build of a series with no directory here gets vanilla upstream and
says so in the log.

## How a build uses this

`mysql-shell_builder.sh` refreshes the series from `sources.conf` and then
applies every enabled entry in `series`, in order, with `patch -p1 -N --fuzz=3`.

Refresh happens **by default**, so builds pick up new fixes from the Percona
fork automatically. If the refresh fails — network, or the fork branch moved or
was deleted — the build falls back to the checked-in patches rather than
failing. Pass `--refresh_patches=0` to skip refreshing and build exactly what is
committed here.

Consequence worth knowing: because refresh is the default, two builds of the
same release tag can differ if the fork branch moved between them. The build
records `PERCONA_PATCHES`, `PERCONA_PATCH_SOURCE` and `PERCONA_PATCH_SHA256` in
`mysql-shell.properties`, and `PROVENANCE` carries per-patch hashes, so any
package can be traced back to the exact patch set it was built from. For a
release you can freeze the set by refreshing once, committing the result, and
building with `--refresh_patches=0`.

## The two kinds of entry

`series` lists patches in apply order, and there are exactly two kinds:

| Entry | Owned by | Refresh behaviour |
|---|---|---|
| `NNNN-*.patch` | `refresh.sh` | regenerated from the fork every refresh |
| anything else | you | file and `series` line preserved untouched |

That is the whole rule. Comment out any line to retire that patch; the
commented state survives refreshes either way.

## Adding a patch that lives on the fork branch

Commit it to the branch named in `sources.conf`. Nothing to do here — the next
build refreshes and picks it up automatically.

## Adding a local patch

Two steps:

```bash
cp my-fix.patch patches/9.7/
echo "my-fix.patch" >> patches/9.7/series
```

Order is where you put the line. Do not name it `NNNN-something.patch` — that
namespace belongs to `refresh.sh` and will be overwritten. Any other name is
safe and is never touched.

If you list a file that does not exist, refresh warns and drops the entry rather
than leaving the build to fail later:

```
refresh: WARNING: 9.7/series lists my-fix.patch but the file is missing; dropped
```

## Retiring a patch

Comment its line out:

```
0001-ps-10416-calculate-and-send-checksum-header-for-uploads.patch
# 0002-ps-10413-improve-chunking-strategy-for-tables-with-the.patch
my-fix.patch
```

This works for both kinds. A retired generated patch stays retired even though
it is still on the fork branch, and a retired local patch keeps its file.

This matters right now: upstream merged the composite-primary-key chunking work
on master as `2e6e6b505` ("BUG#38575174 BUG#39508884 Improve composite PK dump
chunking"), crediting the Percona contribution. It is **not** in 8.4 or 9.x, so
`0002` is still required there. It is also a reimplementation rather than a
merge of this code — upstream does not expose `adaptiveStepStrategy`,
`maxKeyPrefixLength` or `enhanced` — so retiring `0002` on a future master-based
build would remove those options from `util.dumpInstance()`. That is a product
decision, not a packaging one.

## Adding a new shell series

Add a line to `sources.conf` and run `./patches/refresh.sh <series>`. If no
Percona branch exists for that series yet, leave it out — builds will use
vanilla upstream and log that they did.
