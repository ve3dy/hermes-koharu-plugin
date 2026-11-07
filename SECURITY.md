# Security Policy

## What runs

- **No network service.** The plugin runs `koharu-batch` as a short-lived local process for each request. Nothing listens on a port.
- **Process user.** The runner runs as your user and reads only the image paths Hermes passes in. It writes only to the export folder.

## What leaves your machine

Page images and text stay local unless your Koharu translation provider is a remote API. In that case, the text is sent to that provider. Koharu keeps provider API keys in the operating system's keyring.

## Supply chain

- **Koharu source.** The installer builds from the latest release tag of `koharu-rs/koharu`. It checks the cloned source against the commit that tag pointed to when it was resolved, so a moved tag fails the install.
- **Runner.** The runner (`runner/`) is part of this repository and is built locally. No prebuilt binaries are downloaded.
- **Koharu runtime libraries.** Koharu itself downloads its runtime libraries and models from Hugging Face on first use, the same as the desktop app.
- **Plugin dependencies.** The Python plugin uses only the standard library.

## Reporting

- Report plugin issues privately via GitHub security advisories at <https://github.com/ve3dy/hermes-koharu-plugin/security/advisories/new>.
- Report Koharu issues upstream at <https://github.com/koharu-rs/koharu>.
