# Releasing EscapeOS

**Never replace `v0.1.0`.** That tag already has real users. Recutting the same version (force-push tag, overwrite `EscapeOS-0.1.0.ipa`) leaves people on a silent different binary with the same number.

The next public IPA after **0.3.1** is **0.3.2 or higher**. Never replace `v0.1.0` or `v0.1.1` once they have downloads. `v0.1.4` was pulled twice the same day (Extract hidden on iOS 26; pairing Files picker too narrow) and republished with those fixes; do not recut it again. Do not recut `v0.1.5`, `v0.1.6`, `v0.1.8`, `v0.2.0`, `v0.2.1`, `v0.3.0`, or `v0.3.1` once they have downloads.

Verify on a physical iPhone before publishing. CI must not upload release assets.
