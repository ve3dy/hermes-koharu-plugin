# Changelog

## 0.1.0

- `koharu_translate` translates a folder or a list of image files with Koharu's full pipeline (detect, OCR, translate, inpaint, render). It returns PNGs plus `MEDIA:` lines so Telegram can attach them.
- `koharu_status` shows the runner, the translation model and target language, and whether the model server is reachable.
- The `koharu-batch` runner (`runner/`) is built locally against the latest Koharu release, falling back to the last release known to work, with no upstream file changed. It runs headless, with no window and no server, and shares settings (`~/.koharu/config.toml`) and models with the Koharu desktop app.
- Installers for macOS and Linux (`scripts/install.sh`, `scripts/uninstall.sh`) and Windows (`scripts/install.ps1`, `scripts/uninstall.ps1`), all with a dry-run mode.
- CI runs the tests and a full installer build on Linux, Windows and macOS.
