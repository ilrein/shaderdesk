## What's this?

<!-- New scene? Tell us about it and add a screenshot or clip. -->

## Checklist for new scenes

- [ ] `//! title`, `order`, `bloom` and `tags` header
- [ ] GPU time at 4K (`--size 1920x1080 --scale 2 --bench 300`): ___ ms
- [ ] Checked at more than one aspect ratio (e.g. 1512x982 and 1920x1080)
- [ ] Every periodic motion divides 86,400 s (no jump at midnight)
- [ ] Preview rendered (`scripts/render-previews.sh <id>`), and entries added to `docs/index.html` and the README
