# Moving notes from another notebook app

User-facing copy for the import flow, plus developer notes. The in-app text never
names a third-party product; it applies to any app that can export PDFs. The file
name reflects the benchmark app in the research, whose migration path is "export
PDFs from that app"; there is no proprietary-format importer.

## In-app text

**Title:** Bring in notes from another app

**Body:**

You can bring existing notes into this app by exporting them as PDF files from
the app you used before, then importing those PDFs here. Each PDF becomes a new
notebook, or its pages can be inserted into a notebook you already have.

**What to expect**

- Everything you see on the exported pages is kept: handwriting, typed text,
  images and the original document. Page sizes and order are preserved.
- Handwriting in an exported PDF is a picture of the ink. You cannot select,
  move, recolor or erase those old strokes individually, and the eraser will not
  affect them. Anything you write here is fully editable.
- Text that was real text in the original document (for example lecture slides)
  usually stays searchable. Old handwriting becomes searchable only after this
  app's on-device recognition has processed it, and results depend on how the
  pages were exported.
- Outlines, bookmarks, links, audio recordings, flashcards and other features of
  the previous app are not imported.

**Before you delete anything**

Keep your original files and any backups from your previous app. This app does not
read that app's own file format, so the PDFs are the only copy it can use. Your
original files are never modified by importing.

**Tips for a good export**

- Export one notebook at a time, as a PDF with all pages.
- If the other app offers a choice, pick the option that keeps the original
  document's text rather than a flattened image, so slides stay searchable.
- Check the first exported PDF here before exporting the rest.

**Buttons:** Choose PDFs… · Not now

## Confirmation shown after import

"Imported *[title]* ([n] pages). Existing handwriting from the PDF is not
editable as strokes. Your original file was not changed."

## Developer notes

- No decoder for third-party notebook formats is a launch dependency, and none is
  planned; the import path is `ImportKind.pdf` through the normal validated
  import (`Workspace.LibraryServicing.importFiles`).
- Imported PDF bytes are stored unmodified as an immutable asset; the student's
  new ink lives in the ink layer above.
- Search: PDF text layers are indexed as `pdfText`; image-only pages are queued for
  on-device recognition and show as "not yet indexed" until processed.
- Never claim lossless migration, editable imported handwriting, or that the
  previous app's backups can be opened.
