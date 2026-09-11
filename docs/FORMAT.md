# Native format

Schema version: **1** (`DocumentSchema.current`). Encoded with
`DocumentJSON.encoder()` (sorted keys, ISO-8601 dates with fractional seconds).

## 1. Library layout

```
<Application Support>/Courseleaf/Library/
  library.json                      LibraryManifest: folders, trash entries (atomic replace)
  library.lkg.json                  previous manifest (last known good)
  Documents/<DocumentID>.courseleafdoc/     one package per notebook or quick note
  Trash/<DocumentID>.courseleafdoc/         deleted packages until restored or purged
  Catalog/catalog.sqlite            rebuildable index (may be deleted at any time)
  Previews/<DocumentID>/<PageID>.png        disposable thumbnails
  Staging/                          in-progress imports/restores; cleared on launch
```

## 2. Document package

```
<DocumentID>.courseleafdoc/
  manifest.json           Manifest (below)
  manifest.lkg.json       previous committed manifest
  pages/<PageID>-<RevisionID>.json      immutable page record (DocumentCore.Page)
  assets/<xx>/<sha256>.<ext>            immutable content: pdf, png, jpg, ink
  revisions/<RevisionID>.json           DocumentCore.Revision
  tmp/                    staging for the current commit; contents are ignored on open
```

`manifest.json`:

```json
{
  "formatVersion": 1,
  "document": { ...DocumentCore.Document... },
  "pageFiles": { "<PageID>": { "file": "pages/<PageID>-<RevisionID>.json", "sha256": "…" } },
  "assets": { "<AssetID>": { ...DocumentCore.SourceAsset... } },
  "committedAt": "2026-09-11T21:00:00.000Z"
}
```

## 3. Commit protocol (Persistence.DocumentStore)

1. For each `PendingAsset`: write to `tmp/<sha256>.<ext>`, fsync, verify the
   digest, rename into `assets/<xx>/`. An existing file with the same digest
   is reused (never rewritten).
2. For each changed page: write `tmp/<PageID>-<RevisionID>.json`, fsync,
   rename into `pages/`.
3. Write `revisions/<RevisionID>.json` the same way.
4. Build the new manifest; verify every `pageFiles` entry and every asset
   referenced by any live or deleted page exists with the recorded digest.
5. Write `tmp/manifest.json`, fsync; hard-link/copy the current
   `manifest.json` to `manifest.lkg.json`; rename `tmp/manifest.json` over
   `manifest.json`; fsync the package directory.
6. Old page files not referenced by the new manifest, `manifest.lkg.json`,
   or a retained revision are eligible for garbage collection on the next
   maintenance pass (not during commit).

If any step fails the package on disk is unchanged from the reader's point of
view: readers only ever open `manifest.json` (or `manifest.lkg.json` when the
former is missing or invalid) and ignore `tmp/`.

## 4. Archive container (`.courseleaf`)

A ZIP file (stored entries, CRC-32 per entry, no encryption) with:

```
archive.json                       ArchiveManifest
documents/<DocumentID>/manifest.json
documents/<DocumentID>/pages/…     page records
documents/<DocumentID>/assets/…    assets
documents/<DocumentID>/revisions/… (head revision only unless "full history" is requested)
library.json                       only in library backups
```

`archive.json`:

```json
{
  "formatVersion": 1,
  "kind": "document" | "library",
  "createdAt": "…",
  "producer": "Courseleaf <marketing version> (<build>)",
  "entries": [ { "path": "documents/…/manifest.json", "size": 1234, "sha256": "…" } ],
  "totalSize": 123456
}
```

Import validation, all before any data is trusted or copied into the library:

- `formatVersion` must be readable (`DocumentSchema.isReadable`).
- Entry paths must be relative, normalized, without `..`, leading `/`, drive
  letters, NUL or control characters, and must appear in `archive.json`.
- Declared sizes must match the local-header and central-directory sizes;
  `totalSize` and the expansion ratio must be within limits
  (`ArchiveLimits`: 4 GiB total, 200:1 ratio, 50 000 entries).
- Every entry's SHA-256 must match `archive.json`; every asset's file name
  must match its content digest.
- The extracted document must pass `DocumentSnapshot.validate()`.

Documents are restored **as a copy** (new `DocumentID`) unless the caller
asks to replace an identically identified document that is missing from the
library. A failed import never modifies the library.

## 5. Versioning and migration

- `formatVersion` in manifests and archives is `DocumentSchema.current`.
- Adding optional fields does not bump the version. Renaming, removing or
  changing the meaning of a field bumps it and adds a `Migration` in
  Persistence that rewrites a snapshot from version N to N+1.
- A newer unsupported version yields `PersistenceError.unsupportedSchema`,
  and the library shows the document as read-only "needs a newer app"; it is
  never opened as empty.
