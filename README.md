Passmanager
===========

This is a password manager based on [pass](https://www.passwordstore.org/) by Jason Donenfeld.

It is compatible with Firefox [PassFF](https://addons.mozilla.org/en-US/firefox/addon/passff/)
extension.

The main differences with `pass` are:

- Password hierarchy is hidden in an encrypted index instead of using a directory structure.
    - The bash completion still works if a GPG agent is used.
- GPG files are encrypted with hidden recipients (`gpg -R` instead of `gpg -r`).
- All passwords must be encrypted for the same set of users.


TODO
----

- Implement all functionalities supported by pass:
    - commands: `insert`, `grep`
    - extensions
    - completion for `fish` and `zsh`
    - importers
- Improve tree view
