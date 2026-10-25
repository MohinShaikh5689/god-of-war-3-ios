Wine's code page tables (LGPL-2.1-or-later), from willfaust/wine at 9129e9684daaeae70da9435e7c6060e59392634e
(the commit Madeira pins), `nls/c_*.nls`. Madeira bundles only 1252, 20127, 28591 and 437; games that convert
other code pages fail without these (Sekiro throws at start without c_932.nls, Japanese Shift-JIS).
`native/wine/scripts/embed-wine.sh` adds them to the app's `nls/` folder.
