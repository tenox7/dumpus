# Dumpus

A GUI media dumper for macOS. Dufus in reverse: it dumps CD, DVD and USB media to files.

- **ISO**: raw copy of the unmounted media, like `sudo dd if=/dev/rdiskNs0 bs=1m`.
  CDs use the data partition (`diskNs0` or the first data track), other media use the whole disk.
- **TAR**, **RAR**, **ZIP**: the files of the mounted volume (`tar`, `rar`, `zip`).
  RAR uses best compression (`-m5`), a 16 GB dictionary (`-md16g`), solid mode (`-s`) and a recovery record (`-rr`).
  If macOS cannot mount the file system (for example EFS or UFS), only ISO is possible.

Dumpus mounts and unmounts the media as each format needs, then puts it back as it was.
Reading the raw device needs root: Dumpus asks for an admin password, like Dufus.

RAR needs `rar` from [rarlab.com](https://www.rarlab.com) in `/opt/homebrew/bin`, `/usr/local/bin` or `~/bin`.

Build: `make app` (or `make` for a DMG).
