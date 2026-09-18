# Releasing EscapeOS

**Never replace `v0.1.0`.** That tag already has real users. Recutting the same version (force-push tag, overwrite `EscapeOS-0.1.0.ipa`) leaves people on a silent different binary with the same number.

The next public IPA after **0.1.6** is **0.1.7 or higher**. Never replace `v0.1.0` or `v0.1.1` once they have downloads. `v0.1.4` was pulled twice the same day (Extract hidden on iOS 26; pairing Files picker too narrow) and republished with those fixes; do not recut it again. Do not recut `v0.1.5` or `v0.1.6` once they have downloads.

Verify on a physical iPhone before publishing. CI must not upload release assets.
