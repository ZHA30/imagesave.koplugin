# Image Save Plugin (`imagesave.koplugin`)

`imagesave.koplugin` extends KOReader's image viewer with save actions for both the current viewport and the original image.

## Features

- Adds a `Save` button in image viewer windows (when plugin is enabled).
- `Tap Save`: saves the current viewport screenshot (current zoom/pan state).
- `Long-press Save`: saves the original image file/content.

## Settings

Main menu path: `Main menu > More tools > Image save`

- `Image save`: master switch for button injection.
- `Save original`: enables/disables long-press original save on the `Save` button.
  - When turned on, the plugin shows a hint that long-press triggers original save.
- `Save folder: <path>`: destination folder for **original image** saving.
  - If unset, falls back to KOReader screenshot directory.

## Notes:

- Viewport screenshot saving continues to use KOReader's built-in screenshot directory logic.
- Save folder configuration remains available even if `Save original` is off.
