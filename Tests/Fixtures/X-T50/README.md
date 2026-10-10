# X-T50 fixtures

The first 65,536 bytes of four real Fujifilm X-T50 JPEGs (Fine, size M) from the owner's card,
committed with permission on 2026-10-09. That is exactly what FujiCull's T0 read
covers (DESIGN §5.4): the EXIF APP1 segment (65,468 bytes), with the 160 × 120 IFD1 thumbnail and
the Fuji MakerNote. The image data after it is cut off.

| File | Orientation | Exposure | Notes |
|---|---|---|---|
| `DSCF3404-head64k.JPG` | 1 (landscape) | 1/1700 s, f/8, ISO 500, 23 mm, 2026:09:20 05:08:41 | |
| `DSCF3406-head64k.JPG` | 6 (portrait, rotate 90° clockwise) | 1/900 s, f/8, ISO 500, 23 mm, 2026:09:20 05:09:05 | Its thumbnail is stored sideways |
| `DSCF4006-head64k.JPG` | 6 (portrait) | 1/150 s, f/5.6, ISO 250, 23 mm, Astia (FilmMode 0x120) | Added in T13 |
| `DSCF4136-head64k.JPG` | 6 (portrait) | 1/100 s, f/1.4, ISO 1250, 23 mm, Acros + Ye (no FilmMode; Saturation 0x502) | Added in T13 |
