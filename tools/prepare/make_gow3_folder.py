#!/usr/bin/env python3
"""Make the files Olympus needs in Files > On My iPhone > Olympus > gow3 from your own dump.

Runs gow3's prepare.py, link_libc.py, link_modules.py, content_profile.py and patches.py (in
scripts/, from gow3_android) on the dump, the same steps its run.py runs, then puts
boot-linked.bin, content.bin and patches.bin in the output folder. With --copy-game the dump is
copied next to them as game/, so the whole folder can be copied to the iPhone as it is.

Python 3.10+, standard library only. The dump must already have the 01.02 update merged in.
"""
import argparse
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

HERE = Path(__file__).resolve().parent
OUTPUTS = ('boot-linked.bin', 'content.bin', 'patches.bin')


def run(script, *args):
    result = subprocess.run([sys.executable, str(HERE / 'scripts' / script), *map(str, args)])
    if result.returncode:
        sys.exit(f'{script} failed (exit {result.returncode})')


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('game', type=Path, help='the dumped game folder (with eboot.bin, sce_module, sce_sys)')
    p.add_argument('--out', type=Path, default=Path('gow3'), help='output folder (default: ./gow3)')
    p.add_argument('--copy-game', action='store_true', help='also copy the dump to <out>/game (about 30 GB)')
    a = p.parse_args()
    game = a.game.resolve()
    if not (game / 'eboot.bin').is_file():
        sys.exit(f'No eboot.bin in {game}: pass the dump folder itself, not the folder that holds it.')
    if not (game / 'sce_module' / 'libc.prx').is_file():
        sys.exit(f'No sce_module/libc.prx in {game}: the dump is incomplete.')

    a.out.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory() as tmp:
        work = Path(tmp)
        run('prepare.py', game, '--out', work)
        run('link_libc.py', game, '--out', work)
        run('link_modules.py', game, '--out', work)
        run('content_profile.py', game, '--out', work)
        run('patches.py', '--game-dir', game, '--out', work)
        for name in OUTPUTS:
            shutil.copyfile(work / name, a.out / name)

    if a.copy_game:
        target = a.out / 'game'
        if target.exists():
            sys.exit(f'{target} already exists; remove it first or copy the dump yourself.')
        print(f'Copying the dump to {target} ...', flush=True)
        shutil.copytree(game, target)

    print(f'\nDone: {", ".join(OUTPUTS)} in {a.out.resolve()}')
    print('Copy them into Files > On My iPhone > Olympus > gow3, next to the game/ folder'
          + (' (already in the output folder).' if a.copy_game else ' (your dump, renamed to "game").'))


if __name__ == '__main__':
    main()
