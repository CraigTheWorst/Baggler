# Baggler listing artwork

`baggler-curseforge-avatar.png` is a 512×512 RGBA PNG with transparent padding,
made from `addons/Baggler/Assets/baggler-master.png`. It is the project avatar
for addon listing sites, not a game screenshot, and is not part of the install
ZIP. The artwork's origin is described in [PROVENANCE.md](../docs/PROVENANCE.md#artwork).

To rebuild it from the repository root with ImageMagick:

```sh
magick addons/Baggler/Assets/baggler-master.png -trim +repage -resize 480x480 -gravity center -background none -extent 512x512 PNG32:release-assets/baggler-curseforge-avatar.png
```
