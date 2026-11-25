---
name: print-toy
description: Turn a child's wish into a printed toy on the K2 - find two or three proven models, send their pictures, remix the one picked into the CFS colours, slice with the real colours, send the preview, print on "prindi" and keep a record; design our own only for what does not exist. Use when the operator asks for a toy, a figure, a fidget, a flexi animal or anything to print for the children.
---

# Print a toy

Proven models first, our own design last. Three own sculpted figures failed
where a downloaded one printed on the first try, so the loop starts by searching.
The printer, its tools, the colours and the go rule are in khe-meta
`house/k2-printer.md`; the toy record is khe-meta `house/parts/toys/README.md`.
Talk to the operator in Estonian. This file is public: no names or other family
detail here.

1. **The wish.** Take the reference when there is one (a picture, a link, a
   bought toy). Without one ask only what the search needs: which animal or
   thing, about how big, which colours, whether it moves or fidgets, whether it
   goes in a container. Not every wish comes with a picture.
2. **Find**, on the laptop, in the operator's Chrome (agent-vm has no browser):
   Printables and MakerWorld first, others when those are thin. Pick two or three
   proven models: downloads, makes, rating, licence, size and print time. Prefer
   print-in-place, no supports, the designer's own multicolour profile and four
   colours at most. Send each one's picture by SendUserFile with those numbers;
   the operator or the children pick.
3. **Get it.** Printables downloads without a login, MakerWorld with the
   operator logged in. Ask before each download, with its name, source and size.
   The files go to the toy's folder under khe-meta `house/parts/toys/`, so
   agent-vm can slice them too. A downloaded model or a remix of it never goes
   into khe-workshop, an artifact or any public build; most licences allow a
   private remix and forbid sharing it.
4. **Remix.** `k2_import_3mf.py list`, then `extract` with the slot mapping
   (`k2-printer.md` "Colours and flush"). Every colour change costs a flush, so
   keep colour where it reads (a red nose) and drop it where it adds little.
   Scale only within the designer's stated range: a print-in-place joint's
   clearance shrinks with it.
5. **Print.** `k2_slice.py --parts --colours` with the slots' colours, then look
   at the first layer. Follow the print order in `k2-printer.md`: the slice's
   preview goes to the operator with the time and flush grams, again after any
   change, and nothing starts before their "prindi" for that file. A camera frame
   after the first layers.
6. **Record** one row in the toy README: source, designer, licence, slots and
   colours, time, grams, changes, printed date and result.

**Nothing fits.** Design only the missing part. Show concept pictures before
building anything. A mechanism of our own gets a small test piece first. A
container is sized to the toy at the scale it prints. Check the slicer's first
layer, not only our model. Our own parts go to khe-workshop as public source.
