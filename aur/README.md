# AUR packaging

This folder tracks the `PKGBUILD` published as [`keychron-launcher`](https://aur.archlinux.org/packages/keychron-launcher) on the AUR, kept here for reference and so changes go through the same review as the rest of the repo.

Unlike the `.pkg.tar.zst` attached to GitHub releases (which bundles its own copy of Electron), this package depends on the `electron` package already in the Arch repos. That avoids a duplicated Chromium, keeps the install smaller, and means it updates whenever the system `electron` package does.

## Publishing an update

The AUR is a separate git remote, not this repo. Updating it after a new tag here:

```sh
git clone ssh://aur@aur.archlinux.org/keychron-launcher.git aur-keychron-launcher
cp aur/PKGBUILD aur-keychron-launcher/
cd aur-keychron-launcher
makepkg --printsrcinfo > .SRCINFO
git add PKGBUILD .SRCINFO
git commit -m "Update to vX.Y.Z"
git push
```

Requires an AUR account with an SSH public key attached to it (My Account → SSH Public Key at aur.archlinux.org), and the matching private key set up locally, either in `~/.ssh/config` for the `aur.archlinux.org` host or passed to git directly. See the [AUR submission guidelines](https://wiki.archlinux.org/title/AUR_submission_guidelines) for the full walkthrough.

`makepkg -f` locally, from inside this `aur/` folder, builds and verifies the package the same way AUR users will before anything gets pushed.
