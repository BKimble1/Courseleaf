# Support page (draft)

Text for the public support URL required by App Store Connect. Describes the
launch product only. Placeholders in square brackets are filled by the account
owner; do not publish with placeholders.

---

# [APP NAME] support

[APP NAME] is a notebook app for iPad and Apple Pencil for handwriting, PDF
coursework and reviewing your own problem work. Your notes stay on your iPad.

**Contact:** [SUPPORT EMAIL]. Please include your iPad model, iPadOS version and
the app version from Settings → About. Do not send notebooks unless we ask; if we
do, export a copy of the single affected notebook as a `.courseleaf` archive.

## Getting started

- **Create a notebook** from the Library with a title and paper (blank, lined,
  grid, dotted, Cornell or engineering). A quick note is one tap and lands in
  Inbox until you file it in a course.
- **Courses** are folders that also collect a review queue. Nest folders inside a
  course as you like.
- **Import a PDF or image** from Files, drag and drop, or "Open in". Choose a new
  notebook or insert into an existing one.
- **Write** with Pen, Pencil or Highlighter. Finger drawing is off by default;
  turn it on in Settings → Input.

## Problem Pages and review

- Open the Problem Inspector on any page to give it a title, source, Given/Find and
  a result region, and set its status (Unfinished, Check again, Understood).
- Add the page or a region to the course's review queue with an optional prompt.
  Cover the answer with tape and tap to reveal it.
- The review queue is a manual list you work through; it does not schedule reviews
  or track scores.

## Saving and safety

- The editor shows Unsaved, Saving or Saved. "Saved" appears only after the notebook
  is fully written to disk.
- If saving fails (for example the iPad is out of space) the app keeps your last
  saved version and your unsaved changes in memory, and offers Retry or Export a
  copy. Free up space and tap Retry.
- Deleted pages and notebooks go to Trash and can be restored until you empty it.

## Backup and restore

- Settings → Backup → Back up library writes a single `.courseleaf` archive to a
  place you choose in Files. A backup is only reported as complete after it has
  been verified.
- Restore from backup adds notebooks as copies by default, so nothing you have is
  overwritten. Choose "Restore missing only" to bring back notebooks you deleted.
- Backups are not automatic at this time.

## Export and printing

- PDF: original slides stay as text and vectors; your handwriting is drawn on top
  as an image. Links and outlines from the original PDF are not carried over.
- Images: one PNG or JPEG per page.
- `.courseleaf` archive: full editing fidelity, for moving notebooks between iPads
  or keeping an editable backup.
- Tape: choose whether covered answers stay covered, are all covered, or are all
  revealed when exporting.
- Print uses the standard iPadOS print panel.

## Search

Search finds titles, typed text, real PDF text and recognized handwriting or scans
(English). Recognition happens on your iPad in the background. "Not yet indexed"
means pages are still being processed; "No matches" means the search ran on
everything. Settings → Storage → Rebuild search index rebuilds it from your
notebooks without changing them.

## Moving from another app

Export your notebooks from the other app as PDFs and import them here. Handwriting
in those PDFs is visible but not editable as strokes. Keep your original files.
See the in-app guide under Import → Bring in notes from another app.

## Troubleshooting

- **A notebook shows "Needs a newer version":** it was created by a newer app
  version. Update the app; the notebook is not changed or emptied.
- **Search results are missing for a scanned page:** wait for indexing to finish
  (Settings → Storage shows progress) or rebuild the index.
- **Pencil draws nothing:** check Settings → Input → Pencil-only drawing, and that
  the Pencil is paired and charged. In reading mode drawing is disabled.
- **Camera or photo access was denied:** allow it in iPadOS Settings → Privacy &
  Security. Everything else works without it.
- **Something went wrong during import:** nothing was added; check the file opens
  in Files, and that it is a PDF, PNG, JPEG or `.courseleaf` archive.

## What the app does not do (yet)

No account, no sync between devices, no cloud storage, no AI features, no audio
recording, no flashcards, no collaboration. See the privacy policy for what stays
on your device: [PRIVACY URL].

## Reporting a problem

Email [SUPPORT EMAIL] with steps to reproduce. The app collects no diagnostics on
its own; if you have iPadOS analytics sharing on, Apple may share crash reports
with us, which contain no note content.
