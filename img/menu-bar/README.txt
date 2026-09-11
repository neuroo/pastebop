PasteBop menu bar icon
======================

Black artwork on genuine alpha transparency, drawn to read clearly at 18 points.

Files
-----
  PasteBopTemplate.svg          Vector master, 22-unit viewBox. Edit this one.
  PasteBopTemplate.imageset     18-point 1x and 2x, template rendering enabled.
  PasteBopTemplate@3x.png       54-pixel export.
  PasteBopTemplate-master.png   440-pixel transparent preview.
  preview.png                   Light and dark presentations, with 18, 22 and
                                24-pixel samples below the enlarged mark.

Using them
----------
Scripts/make-icons.swift copies the imageset into App/Assets.xcassets as
"MenuBarIcon" and keeps the template rendering intent, so the glyph follows the
menu bar's own tint in light and dark. Re-run it after editing the SVG and
re-exporting the PNGs.

  https://developer.apple.com/documentation/appkit/nsimage/istemplate
