import Testing
@testable import NibCore

@Suite("Diff parsing")
struct DiffParserTests {
    @Test func modifiedFile() {
        let files = Fixture.files(Fixture.modified("Sources/App.swift", removed: ["a", "b"], added: ["c"]))
        #expect(files.count == 1)
        #expect(files[0].path == "Sources/App.swift")
        #expect(files[0].status == .modified)
        #expect(files[0].additions == 1)
        #expect(files[0].deletions == 2)
        #expect(files[0].hunks.count == 1)
        #expect(files[0].hunks[0].hasPrefix("@@"))
    }

    @Test func addedAndDeletedFiles() {
        let files = Fixture.files(Fixture.added("New.swift", lines: ["one", "two"]), Fixture.deleted("Old.swift", lines: 3))
        #expect(files.map(\.path) == ["New.swift", "Old.swift"])
        #expect(files[0].status == .added)
        #expect(files[0].additions == 2)
        #expect(files[1].status == .deleted)
        #expect(files[1].deletions == 3)
    }

    @Test func pureRename() {
        let raw = """
        diff --git a/Old Name.swift b/New Name.swift
        similarity index 100%
        rename from Old Name.swift
        rename to New Name.swift
        """
        let file = DiffParser.parse(raw)[0]
        #expect(file.status == .renamed)
        #expect(file.oldPath == "Old Name.swift")
        #expect(file.path == "New Name.swift")
        #expect(file.hunks.isEmpty)
        #expect(file.displayPath == "Old Name.swift → New Name.swift")
    }

    @Test func binaryFile() {
        let raw = """
        diff --git a/logo.png b/logo.png
        new file mode 100644
        index 0000000..7777777
        Binary files /dev/null and b/logo.png differ
        """
        let file = DiffParser.parse(raw)[0]
        #expect(file.isBinary)
        #expect(file.status == .added)
        #expect(file.path == "logo.png")
    }

    @Test func pathWithSpaces() {
        #expect(DiffParser.pathFromHeader("diff --git a/My Folder/a b.swift b/My Folder/a b.swift") == "My Folder/a b.swift")
    }

    @Test func dashesInsideHunkAreContentNotHeaders() {
        // Removing a line that starts with "-- " shows up as "--- " inside the hunk.
        let raw = """
        diff --git a/schema.sql b/schema.sql
        index 1111111..2222222 100644
        --- a/schema.sql
        +++ b/schema.sql
        @@ -1,2 +1,2 @@
        --- old comment
        +++ new comment
         SELECT 1;
        """
        let file = DiffParser.parse(raw)[0]
        #expect(file.path == "schema.sql")
        #expect(file.additions == 1)
        #expect(file.deletions == 1)
    }

    @Test func multipleHunks() {
        let file = Fixture.files(Fixture.big("Big.swift", hunks: 3, linesPerHunk: 2))[0]
        #expect(file.hunks.count == 3)
        #expect(file.additions == 6)
    }

    @Test func emptyInput() {
        #expect(DiffParser.parse("").isEmpty)
    }
}
