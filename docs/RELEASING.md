# Releasing

```sh
git tag v0.2.0 && git push --tags
```

`.github/workflows/release.yml` runs the tests, builds the zip and DMG with
`scripts/release.sh`, publishes the GitHub Release, and pushes the updated cask to
`armandrt/homebrew-tap` when the `TAP_TOKEN` secret exists (a fine-grained token with Contents
read/write on the tap). Without the secret, update the tap by hand:

```sh
scripts/update-cask.sh 0.2.0 --sha256 <zip line of SHA256SUMS.txt> \
  --output <tap checkout>/Casks/claude-account-switcher.rb
```

The same release can be cut locally: `scripts/release.sh 0.2.0` writes everything into `dist/`.
