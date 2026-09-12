// Umbrella header for the CSQLite target: it exposes the platform's SQLite to
// Swift. This is a regular C target rather than a `.systemLibrary` because
// Xcode's local-package integration does not create a build target for system
// libraries, which broke the iOS app build ("missing target PACKAGE-TARGET:CSQLite").
// `sqlite3.h` ships in the iOS/macOS SDKs and in libsqlite3-dev on Linux; the
// library itself is linked through the target's `linkedLibrary("sqlite3")`.
#ifndef CSQLITE_H
#define CSQLITE_H

#include <sqlite3.h>

#endif /* CSQLITE_H */
