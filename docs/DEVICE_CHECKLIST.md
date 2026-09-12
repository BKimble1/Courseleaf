# Physical iPad checklist

Fifteen minutes with an iPad and an Apple Pencil, for the things no simulator
and no test in this repository can answer. Everything here is **pending** until
someone runs it; nothing below has been verified on hardware.

Write the result next to each line and copy the failures into
`docs/VALIDATION.md`. "Feels wrong" is a useful answer — say what it felt like.

## Before you start

Update Courseleaf from TestFlight, open it, and check your notebooks are all
there and open normally. **If anything is missing, stop and say so** — that is
the only result that matters more than the rest of this list put together.

## 1. Writing (the whole point)

- [ ] Write a sentence. Does the ink keep up with the pen, or lag behind the tip?
- [ ] Write fast for ten seconds. Any stutter, any dropped stroke?
- [ ] Rest your palm on the page and write. Does the palm ever draw?
- [ ] Write near the top of the page, under the toolbar. Does the toolbar get in
      the way of where you want to write?

## 2. The new toolbar

- [ ] From a black pen, tap the yellow highlighter favourite. **One tap?**
- [ ] Tap the black pen favourite again. **One tap?**
- [ ] Tap a different colour swatch. Does the pen change immediately?
- [ ] Tap a different width. Does the next stroke look different?
- [ ] Long-press the pen. Do its options open without a tap having done it?
- [ ] Turn the iPad to portrait, then landscape. Do the controls still fit and
      still make sense?
- [ ] Put the app in Split View at about half width, then narrower. Is anything
      too small to hit? Can you still reach the eraser and undo?
- [ ] Settings ▸ Input ▸ Left-handed layout. Do the controls move to the other
      side **without reversing their order**?

## 3. Undo

- [ ] Draw one stroke and immediately undo it. Does it go?
- [ ] Draw three quick strokes. Does it take three undos to clear them?
- [ ] Pause in the middle of a long stroke, finish it, then undo once. Does the
      whole stroke go, or only half of it?
- [ ] Three-finger swipe left to undo, right to redo. Same history as the button?
- [ ] Clear a page just after writing on it, then undo. Does the writing you had
      just done come back?
- [ ] Tap into a text box, type, and press ⌘Z on a keyboard. Does it undo the
      *typing* rather than the last stroke? Do the arrow keys move the cursor
      rather than turning the page?

## 4. Scribble to erase (off by default)

Turn it on in Settings ▸ Writing gestures, then:

- [ ] Cross a word out with the pen, back and forth four or five times. Does it
      go?
- [ ] Is the writing tool still the pen afterwards?
- [ ] One undo — does the word come back, **without** the scribble you drew?
- [ ] Now the important half. Draw each of these and check **nothing is erased**:
      a sine wave, a row of "eeee", a shaded-in box, a few hatching lines, a
      lightning-bolt zigzag, and a large Σ.
- [ ] Scribble over a PDF page, a photo and a text box. Nothing should be
      removed but handwriting.
- [ ] Try it zoomed right in and right out.

## 5. Draw and hold (on by default)

- [ ] Draw a rough circle and hold the pen still at the end. Does a clean circle
      appear before you lift?
- [ ] Without lifting, drag to make it bigger. Does it follow?
- [ ] Lift. Is it one undo to get your original stroke back?
- [ ] Draw a diagonal line at about 30°. Does it stay diagonal?
- [ ] Draw a nearly level line. Does it snap flat?
- [ ] Write a sentence with ordinary pauses. Does it ever try to correct your
      handwriting?
- [ ] Pinch to zoom and two-finger scroll while drawing is going on. Still fine?

## 6. Search and review

- [ ] Search for a word, tap the result. Does it open the right page **and show
      you where on the page**?
- [ ] Open a review item. Can you see the work, not just a description of it?
- [ ] Reveal the answer. Does the picture change to show it?

## 7. Saving, and coming back

- [ ] Write something, then swipe up to the Home Screen immediately. Reopen.
      Is it there?
- [ ] Write something and force-quit the app from the app switcher within a
      second or two. Reopen. Is it there?
- [ ] Write on several pages, scrolling between them quickly. Reopen the
      notebook. Is everything on every page?
- [ ] Export a page to PDF immediately after writing on it. Is the writing in
      the PDF?

## 8. Speed, with a heavy notebook

Use the biggest notebook you have, and a page with a lot of writing on it.

- [ ] Scroll quickly through it. Smooth, or does it hitch?
- [ ] Zoom in and out on a dense page.
- [ ] Open the 300-page PDF if you have one imported. How long to open, and how
      does it scroll?
- [ ] Leave it open for ten minutes of normal use. Does it slow down or get warm?

## What to send back

The failures, in your own words, plus: iPad model, iPadOS version, Pencil
generation, and the build number from Settings ▸ About Courseleaf. A note that
something "felt laggy" with the model attached is more useful than a number.
