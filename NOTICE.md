# Attribution and release scope

The root MIT license covers original Nixi contributions. It does not replace
upstream copyright notices or grant rights to third-party assets.

| Component | Source | Notice |
| --- | --- | --- |
| Dotfiles-derived framework, shell helpers, themes and `hey` foundations | [Henrik Lissner's dotfiles](https://github.com/hlissner/dotfiles) | [MIT](licenses/hlissner-dotfiles.txt) |
| Vendored Janet `cmd` | [ianthehenry/cmd, b4308de](https://github.com/ianthehenry/cmd/tree/b4308de361d0f90dd96cc0f9a8dc6881e0e851c6) | [MIT](licenses/janet-cmd.txt) |
| Vendored Janet `judge` | [ianthehenry/judge, 10754df](https://github.com/ianthehenry/judge/tree/10754df781b34068e05291951db786933ec6b681) | [MIT](licenses/janet-judge.txt) |
| Vendored Janet `spork` | [janet-lang/spork, ca774c4](https://github.com/janet-lang/spork/tree/ca774c40040b5b02c6c08a9f23a526523dd4a55e) | [MIT](licenses/janet-spork.txt) |
| Local GNU Emacs and Flymake security patches | [GNU Emacs](https://www.gnu.org/software/emacs/) | [GPL-3.0-or-later](licenses/gnu-emacs.txt); retain the upstream notices |
| Generated/adapted Powerlevel10k lean prompt | [romkatv/powerlevel10k](https://github.com/romkatv/powerlevel10k) | [MIT](licenses/powerlevel10k.txt) |

Janet dependency revisions are also recorded in `packages/hey-janet-deps.nix`.
The maintainer approved the standalone `bin/tmuxsel` utility for public export.
It is packaged separately from Hey; this approval does not include other
consumer-owned convenience scripts or private repository history.
The build fetches native dependencies per platform rather than redistributing
locally compiled libraries. Nixpkgs packages and flake inputs retain their own
licenses; a source release is not a license grant for all fetched dependencies.

`modules/shared/themes/alucard/config/wallpaper.png` is deliberately excluded
from the release manifest: its redistribution provenance has not been verified.
The theme does not directly reference this file. Existing local copies remain
untouched. Do not add it to a public release without a separate rights review.

This inventory documents known provenance, not a complete legal audit. Before
the first public release, the maintainer must confirm that remaining original
or inherited code/assets can be distributed under these notices. Preserve
attribution when replacing personal project metadata with a collective name.

The GNU Emacs and GNU ELPA Flymake patches in `packages/` contain changes under
GPL-3.0-or-later, outside the original Nixi MIT grant. The
[GNU license copy](licenses/gnu-emacs.txt) comes byte-for-byte from the
hash-verified Emacs release archive. Retain those terms and upstream notices.
