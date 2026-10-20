import Testing
@testable import OMSOCR

struct MarkdownTablesTests {
    @Test func aPipeTableBecomesRowsOfCells() {
        let text = """
        Prices, from the page:

        | Plan | Storage | Price |
        | :--- | :-----: | ----: |
        | Free | 5 GB | $0 |
        | Pro | 1 TB | $9.99 |

        Billed monthly.
        """
        let tables = MarkdownTables.tables(in: text)
        #expect(tables == [OCRTable(rows: [["Plan", "Storage", "Price"], ["Free", "5 GB", "$0"], ["Pro", "1 TB", "$9.99"]])])
        #expect(tables.first?.tsv == "Plan\tStorage\tPrice\nFree\t5 GB\t$0\nPro\t1 TB\t$9.99")
    }

    @Test func outerPipesMayBeLeftOutAndRowsAreEvenedOut() {
        let text = """
        名称 | 数量
        --- | ---
        苹果 | 3 | extra
        梨
        香蕉 |
        """
        // "梨" has no pipe: the table ends before it.
        #expect(MarkdownTables.tables(in: text) == [OCRTable(rows: [["名称", "数量"], ["苹果", "3"]])])
        #expect(MarkdownTables.tables(in: "a | b\n--|--\n| x |") == [OCRTable(rows: [["a", "b"], ["x", ""]])])
    }

    @Test func escapedPipesAndPipesInCodeStayInTheirCell() {
        let text = """
        | Operator | Meaning |
        |---|---|
        | `a | b` | bitwise or |
        | \\| | a pipe |
        | $\\lvert x \\rvert$ | absolute value |
        """
        let rows = MarkdownTables.tables(in: text).first?.rows
        #expect(rows?[1] == ["`a | b`", "bitwise or"])
        #expect(rows?[2] == ["|", "a pipe"])
        #expect(rows?[3] == ["$\\lvert x \\rvert$", "absolute value"])
    }

    @Test func severalTablesAreFoundInOrder() {
        let text = "| a |\n|---|\n| 1 |\n\nBetween.\n\n| b | c |\n|---|---|\n| 2 | 3 |"
        let tables = MarkdownTables.tables(in: text)
        #expect(tables.count == 2)
        #expect(tables.last?.rows == [["b", "c"], ["2", "3"]])
    }

    @Test func whatOnlyLooksLikeATableIsNotOne() {
        // A rule under a line, a header whose width differs from its delimiter row, text in a code block.
        #expect(MarkdownTables.tables(in: "Title\n---\nBody").isEmpty)
        #expect(MarkdownTables.tables(in: "| a | b | c |\n|---|---|\n| 1 | 2 | 3 |").isEmpty)
        #expect(MarkdownTables.tables(in: "```\n| a | b |\n|---|---|\n| 1 | 2 |\n```").isEmpty)
        #expect(MarkdownTables.tables(in: "~~~~md\n| a |\n|---|\n~~~~\n| c |\n|---|\n| 3 |").count == 1)
        #expect(MarkdownTables.tables(in: "if a | b {\n}").isEmpty)
    }
}
