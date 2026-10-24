# Lamella&trade; interpreter firmware

![Status](https://img.shields.io/badge/status-in_development-orange)

This repository contains firmware for running Lamella interpreters on microcontroller boards.

Lamella is a multi-language toolchain; its source is in the [lamellaproject/lamella](https://github.com/lamellaproject/lamella) repository.

Interpreter firmware images are precompiled for each board.  To download an interpreter for your board, see the [firmware releases](https://github.com/lamellaproject/lamella-interpreter-firmware/releases) in this repository.

## Status

Lamella is in development and is **not yet ready for use**.

## Install a Lamella interpreter onto a microcontroller (example)

The method for installing an interpreter onto a microcontroller varies by board. 

As an example, to install a Lamella interpreter onto a Raspberry Pi Pico 2:

1. Download a Lamella interpreter for your board from the releases page.
2. Hold the board's BOOTSEL button while you connect the board to your
   computer. A drive named RP2350 will appear.
3. Copy the interpreter firmware (`.uf2` file) onto that `RP2350` drive.
4. The board will automatically reboot, starting the interpreter.

## How a release is built

`tools/build-images.ps1` builds an image for every board in `tools/boards.json` from the Lamella source (at the
release's tag).

Build requirements:
- PowerShell 7
- Rust (through rustup)

## License

Dual licensed under either of

- MIT license ([LICENSE-MIT](LICENSE-MIT))
- Apache License, Version 2.0 ([LICENSE-APACHE](LICENSE-APACHE))

at your option.

Compiled interpreter firmware may contain third-party software. Each release's `THIRD-PARTY-NOTICES.txt` lists third-party components and those components' licenses.

<sub>Lamella is a trademark of Lamella LLC.</sub>
