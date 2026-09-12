# App Store metadata (draft)

Draft listing for App Store Connect. Every claim maps to launch behaviour in
`docs/PRODUCT_SPEC.md`; nothing unimplemented is mentioned. Placeholders in
square brackets are decided by the account owner. Re-check character limits in
App Store Connect at submission time (name 30, subtitle 30, promotional text 170,
keywords 100, description 4000 as of the research date).

## Identity

- **Name:** [PUBLIC NAME] (Courseleaf is a codename and is not cleared)
- **Subtitle (≤ 30):** Handwriting and PDF notes for study
- **Bundle ID:** [set in `App/project.yml`; placeholder `dev.courseleaf.app`]
- **SKU:** [OWNER CHOICE]
- **Primary category:** Productivity · **Secondary:** Education
- **Age rating:** answers all "None" (no user-generated content sharing, no web
  access, no gambling, no contests); expected 4+
- **Price:** [Free | Paid | Free with optional one-time unlock — see RELEASE_CHECKLIST #15]
- **Support URL:** [SUPPORT URL] · **Privacy Policy URL:** [PRIVACY URL]
- **Copyright:** © [YEAR] [OWNER NAME]

## Promotional text (≤ 170)

Write by hand, annotate lecture PDFs and turn your own problem work into a review
list. Everything stays on your iPad. No account, no subscription, no cloud.

## Description

[PUBLIC NAME] is a notebook for iPad and Apple Pencil built for coursework: write
by hand, mark up lecture slides and worksheets, and come back to the problems you
need to practise.

WRITE AND ANNOTATE
• Pen, pencil and highlighter with width and colour presets
• Pencil-only drawing by default; finger drawing if you want it
• Pixel and whole-stroke erasing, lasso selection, text boxes, images, basic shapes
• Lock objects, bring to front or send to back, undo and redo
• Original paper: blank, lined, grid, dotted, Cornell and engineering

PDF COURSEWORK
• Import PDFs and images from Files, drag and drop or Open in
• Scan paper pages with the camera
• Original documents are never modified; your notes go on top
• Reading mode with tap-to-follow links and the PDF's outline

PROBLEM PAGES AND REVIEW
• Give any page a problem title, source, Given and Find, and a result region
• Set a status: Unfinished, Check again, Understood
• Send a page or a region to your course's review list with a prompt
• Cover answers with tape, reveal them when you are ready, and jump back to the page

FIND YOUR WORK
• Search titles, typed text, real PDF text and recognized handwriting (English)
• On-device recognition; see clearly what is still being indexed

YOUR FILES, YOUR IPAD
• Notebooks stay on your iPad; nothing is uploaded
• Visible save status: "Saved" means saved
• Recoverable trash for pages and notebooks
• Export PDFs and images, print, or export editable archives
• Full library backup to a location you choose, with verified restore

WHAT IT IS NOT
No account, no cloud sync, no AI, no audio recording, no flashcards. It is a
notebook that keeps your work safe and findable.

## Keywords (≤ 100 characters)

notes,handwriting,pencil,pdf,annotate,notebook,study,college,lecture,review,paper

## What's New (1.0)

First release.

## Screenshots (from the implemented app only)

Required sets: 13" iPad (2064×2752 / 2752×2064) and 11" iPad. Planned frames:

1. Editor with handwritten problem work on lined paper, toolbar visible
2. Annotated lecture PDF in landscape
3. Problem Inspector open on a Problem Page
4. Course review queue with a covered answer
5. Library grid with covers and courses
6. Search results showing match kinds and indexing state
7. Export sheet (PDF / image / archive, tape policy)

No device frames with text overlays claiming unlisted features.

## App Review notes (draft)

- No sign-in. Launch the app and tap "New notebook".
- To test import: share the attached sample PDF (`Fixtures/text-and-outline.pdf`)
  to the app or use Import in the Library.
- To test the review workflow: open a page → Problem Inspector → set a title →
  "Add page to review" → Library → the course → Review.
- Camera is used only for "Scan page"; photo library only for "Insert photo".
- No network requests are made by the app.
- [If the unlock ships] Product ID [PRODUCT ID], non-consumable; everything else is
  usable without it, and exports never require it.

## App privacy (App Store Connect answers)

**Data Not Collected.** The app collects no data of any kind. Re-verify against the
final build before answering (see `RELEASE_CHECKLIST.md` #6–#7).

## In-app purchase metadata (only if RELEASE_CHECKLIST #15 chooses the unlock)

- Reference name: [PUBLIC NAME] Unlock · Product ID: [PRODUCT ID] · Type: Non-consumable
- Display name (≤ 30): [PUBLIC NAME] Unlock
- Description (≤ 45): [what it unlocks — must match the configured gate]
- Review screenshot: the purchase sheet from the implemented app
