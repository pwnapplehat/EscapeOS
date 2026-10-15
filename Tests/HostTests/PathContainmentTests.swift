import Foundation

/// The check behind Import from Files. Issue #4: a new file, and Keep Both, were rejected as
/// "outside this app's data" because the container is reported as /private/var/... and the
/// previous standardizingPath-based comparison normalized an existing folder and a not-yet-created
/// file differently.
func runPathContainmentTests() {
    T.section("PathContainment")

    let container = "/private/var/mobile/Containers/Data/Application/ABCD"
    let documents = container + "/Documents"

    // The exact cases from the bug report.
    T.check(PathContainment.isInside(documents + "/new.txt", root: documents), "a new file in the folder is inside")
    T.check(PathContainment.isInside(documents + "/old 2.txt", root: documents), "Keep Both's numbered name is inside")
    T.check(PathContainment.isInside(documents + "/old.txt", root: documents), "an existing file (Replace) is inside")
    T.check(PathContainment.isInside(documents + "/Sub/Deeper/x.bin", root: documents), "nested paths are inside")
    T.check(PathContainment.isInside(documents, root: documents), "the folder itself counts")

    // /var and /private/var are the same place.
    T.check(
        PathContainment.isInside("/var/mobile/Containers/Data/Application/ABCD/Documents/x", root: documents),
        "/var spelling matches /private/var root"
    )
    T.check(
        PathContainment.isInside(documents + "/x", root: "/var/mobile/Containers/Data/Application/ABCD/Documents"),
        "/private/var path matches /var root"
    )
    T.check(PathContainment.isInside("/private/tmp/a/b", root: "/tmp/a"), "/private/tmp aliases /tmp")
    T.check(PathContainment.isInside("/private/etc/hosts", root: "/etc"), "/private/etc aliases /etc")

    // Messy but equivalent spellings.
    T.check(PathContainment.isInside(documents + "//./x.txt", root: documents + "/"), "extra slashes and dots are ignored")
    T.check(PathContainment.isInside(documents + "/a/../b.txt", root: documents), ".. that stays inside is fine")

    // Everything that must stay rejected.
    T.check(!PathContainment.isInside(documents + "/../Library/x", root: documents), ".. escaping the folder is rejected")
    T.check(!PathContainment.isInside(documents + "/a/../../x", root: documents), "a deeper .. escape is rejected")
    T.check(!PathContainment.isInside(container + "/Documents2/x", root: documents), "a sibling sharing a name prefix is rejected")
    T.check(!PathContainment.isInside(container, root: documents), "the parent folder is rejected")
    T.check(
        !PathContainment.isInside("/private/var/mobile/Containers/Data/Application/OTHER/Documents/x", root: documents),
        "another app's container is rejected"
    )
    T.check(!PathContainment.isInside("/anything", root: "/"), "an empty root never matches")
    T.check(!PathContainment.isInside("/private/other/x", root: "/other"), "only var, tmp and etc alias /private")
    T.check(!PathContainment.isInside("/privatevar/x", root: "/var"), "a name that merely starts with private is not an alias")

    // components(of:) itself.
    T.equal(PathContainment.components(of: "/private/var/a//b/./c"), ["var", "a", "b", "c"], "components normalize")
    T.equal(PathContainment.components(of: "/a/b/../../.."), [], ".. past the top is clamped")
    T.equal(PathContainment.components(of: "/private"), ["private"], "a bare /private is left alone")
}
