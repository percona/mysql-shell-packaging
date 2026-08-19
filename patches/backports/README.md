# Upstream backports

Fixes taken from upstream mysql-shell that the version being built predates.
They are applied to every build, independently of `--apply_patches`, because
without them the build fails outright on at least one supported distribution.
This is what separates them from the Percona series in `patches/<version>/`,
which carries product changes and can be switched off.

Each file is the unmodified output of `git show <commit>` from
https://github.com/mysql/mysql-shell, so it keeps the upstream commit message
and SHA as its provenance.

A patch that no longer applies is skipped with a note, on the assumption that
the version being built already contains it. Once every supported version
includes a fix, delete the file.

## Contents

| Patch | Upstream commit | Why it is needed |
|---|---|---|
| `0001-Fix-bundled-shared-library-handling-on-ELF.patch` | `fa46085c1` | Shell writes an RPATH into the bundled authentication plugins with patchelf. On Ubuntu `dh_strip` runs debugedit first, which corrupts the patched DSO, and the build dies in `override_dh_strip` with "corrupt string table index". Upstream stops writing the RPATH for plugins that only need system libraries, keeping it for the WebAuthn plugin so it still finds the bundled libfido2. The same commit adds the bundled Abseil hash library to the protobuf link interface. |
