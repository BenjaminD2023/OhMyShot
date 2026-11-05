import Foundation

/// What the app and the text reader (Helpers/TextReader, a process of its own) say to each other: one JSON object a
/// line, a `Job` on the reader's standard input and an `Answer` for it on its standard output, the two matched by `id`.
/// The app's two senders (`TextReaderTool`, `HistoryTextReader`) and the reader itself all encode and decode these, so
/// a field one side learns of is one the other has; the reader's main.swift tells in prose what each job and answer
/// holds.
///
/// A field without a value is left out of its line rather than said as null, and the names are the fields' own: the
/// lines are what they were when each side declared the messages for itself, which the tests' stand-in readers, shell
/// scripts matching the lines as text, rely on.
public enum TextReaderWire {
    /// What the app asks the reader to do with one picture, or with none. Which fields it names says what that is
    /// (`mode`).
    public struct Job: Codable, Sendable, Equatable {
        /// Said again by the answer for this job.
        public var id: String
        /// The picture to read; none for a job that reads nothing (warming, tidying).
        public var path: String?
        /// For a reading assembled as Capture Text assembles it, whether lines a paragraph wraps onto are joined;
        /// without it, the text kept for the history's search.
        public var joinsWrappedLines: Bool?
        /// A PP-OCR model pack's folder, to read with beside Vision where the picture holds Chinese or Japanese (L2
        /// beside L1, Docs/ocr.md › L2 beside L1).
        public var pack: String?
        /// With `pack`: the pack reads the picture alone, and the answer holds its lines.
        public var lines: Bool?
        /// With a pack, nothing is read: its models are loaded, their first load compiling them for the Neural Engine.
        public var warm: Bool?
        /// The formula pack's folder, to read the picture as one formula (Capture Formula; Docs/ocr.md › The formula
        /// pack).
        public var formula: String?
        /// The formula pack's folder, to find the formulas in the picture and read each (Docs/ocr.md › Formulas among
        /// text).
        public var formulas: String?
        /// Nothing is read: what Core ML keeps in the reader's Caches folder of models that are gone is removed
        /// (`CompiledModelCache`).
        public var tidy: Bool?
        /// The VLM pack's folder, to read the tables and charts the layout model finds (Docs/ocr.md › The VLM pack).
        public var vlm: String?
        /// With `vlm`: what the VLM reads the whole picture as, a `PaddleOCRVLReader.Task` by name ("ocr", "table",
        /// "formula", or "chart"). Nothing in the app asks for it; it is there to check the VLM from the shell.
        public var task: String?
        /// How long the VLM may read, in seconds, before what is left stays as Vision read it.
        public var seconds: Double?
        /// What to take the system's memory pressure to be, rather than ask the kernel: for checking what happens when
        /// it is pressed.
        public var pressure: MemoryPressure?

        public init(
            id: String, path: String? = nil, joinsWrappedLines: Bool? = nil, pack: String? = nil, lines: Bool? = nil, warm: Bool? = nil,
            formula: String? = nil, formulas: String? = nil, tidy: Bool? = nil, vlm: String? = nil, task: String? = nil, seconds: Double? = nil,
            pressure: MemoryPressure? = nil
        ) {
            self.id = id
            self.path = path
            self.joinsWrappedLines = joinsWrappedLines
            self.pack = pack
            self.lines = lines
            self.warm = warm
            self.formula = formula
            self.formulas = formulas
            self.tidy = tidy
            self.vlm = vlm
            self.task = task
            self.seconds = seconds
            self.pressure = pressure
        }

        /// What a job asks for, told by the fields it names. A job naming more than one of these is the first that
        /// applies, in the order they are declared.
        public enum Mode: Equatable, Sendable {
            /// `tidy`.
            case tidy
            /// `vlm` with `warm`: the VLM pack is loaded.
            case warmVLM(pack: String)
            /// `vlm` with `task`: the VLM pack reads the whole picture as that.
            case vlm(pack: String, task: String)
            /// `formula` with `warm`: the formula pack's models are compiled.
            case warmFormula(pack: String)
            /// `formula`: the formula pack reads the picture as one formula.
            case formula(pack: String)
            /// `pack` with `warm`: the PP-OCR pack is loaded.
            case warmPack(pack: String)
            /// `pack` with `lines`: the pack's own lines, alone.
            case lines(pack: String)
            /// `formulas` or `vlm` without `joinsWrappedLines`: the formulas, tables, and charts in the picture, after a
            /// line saying how many there are to read (`Answer.found(id:formulas:tables:)`).
            case elements
            /// The text, read beside `pack` when there is one; with `joinsWrappedLines` and `formulas` or `vlm`, the
            /// formulas, tables, and charts in the picture are put into it.
            case text
        }

        public var mode: Mode {
            if tidy == true { return .tidy }
            if let vlm {
                if warm == true { return .warmVLM(pack: vlm) }
                if let task { return .vlm(pack: vlm, task: task) }
            }
            if let formula { return warm == true ? .warmFormula(pack: formula) : .formula(pack: formula) }
            if warm == true, let pack { return .warmPack(pack: pack) }
            if lines == true, let pack { return .lines(pack: pack) }
            if formulas != nil || vlm != nil, joinsWrappedLines == nil { return .elements }
            return .text
        }
    }

    /// What the reader says back for a job: its answer, or, before the answer to a job for the formulas, tables, and
    /// charts in a picture, how many it found to read (`found(id:formulas:tables:)`).
    public struct Answer: Codable, Sendable, Equatable {
        /// The job's.
        public var id: String
        /// The text read; the VLM's reading for a `task`; empty after warming.
        public var text: String?
        /// The pack's own lines, for `lines`.
        public var lines: [TextReaderTool.Line]?
        /// The formula read, for `formula`.
        public var latex: String?
        /// How the formula pack's reading, or the VLM's for a `task`, ended.
        public var ending: Ending?
        /// How many formulas, tables, and charts there are to read, said before they are read. No answer says it: it
        /// is what tells that line apart (`progress`).
        public var found: Int?
        /// Of `found`, how many are tables and charts.
        public var foundTables: Int?
        public var formulas: [TextReaderTool.FoundFormula]?
        public var tables: [TextReaderTool.FoundTable]?
        /// Tables and charts found but left to Vision, the system being short of memory for the VLM.
        public var tablesLeft: Int?
        /// How many entries tidying removed.
        public var removed: Int?
        /// Why the reader couldn't do what the job asked.
        public var error: String?

        public init(
            id: String, text: String? = nil, lines: [TextReaderTool.Line]? = nil, latex: String? = nil, ending: Ending? = nil,
            found: Int? = nil, foundTables: Int? = nil, formulas: [TextReaderTool.FoundFormula]? = nil,
            tables: [TextReaderTool.FoundTable]? = nil, tablesLeft: Int? = nil, removed: Int? = nil, error: String? = nil
        ) {
            self.id = id
            self.text = text
            self.lines = lines
            self.latex = latex
            self.ending = ending
            self.found = found
            self.foundTables = foundTables
            self.formulas = formulas
            self.tables = tables
            self.tablesLeft = tablesLeft
            self.removed = removed
            self.error = error
        }

        /// The line said before the formulas, tables, and charts in a picture are read, saying how many there are: the
        /// one line for a job that isn't its answer.
        public static func found(id: String, formulas: Int, tables: Int) -> Answer {
            Answer(id: id, found: formulas + tables, foundTables: tables)
        }

        /// What a line said before the reading (`found(id:formulas:tables:)`) says there is to read; nil for an answer.
        public var progress: TextReaderTool.Found? {
            found.map { TextReaderTool.Found(formulas: $0 - (foundTables ?? 0), tables: foundTables ?? 0) }
        }
    }

    /// How a reading ended: the formula pack's (`FormulaReading.Ending`: `end`, `repeats`, `cacheFull`, `deadline`), or
    /// the VLM pack's for a `task` (`PaddleOCRVL.Ending`: `end`, `length`, `stopped`), by the same names.
    public enum Ending: String, Codable, Sendable {
        /// The model said it was done: the reading is whole.
        case end
        /// The formula model repeated itself and was stopped.
        case repeats
        /// The formula model filled its decoder's cache.
        case cacheFull
        /// The formula model ran past the deadline.
        case deadline
        /// The VLM read as many tokens as it may.
        case length
        /// The VLM was told to stop (a deadline, a cancelled reading).
        case stopped
    }
}

extension TextReaderWire.Job {
    /// As synthesized, but a pressure the reader has no name for is no pressure at all: the reader asks the kernel and
    /// still answers, where failing the whole line would leave the app waiting for an answer that never comes.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(String.self, forKey: .id),
            path: try container.decodeIfPresent(String.self, forKey: .path),
            joinsWrappedLines: try container.decodeIfPresent(Bool.self, forKey: .joinsWrappedLines),
            pack: try container.decodeIfPresent(String.self, forKey: .pack),
            lines: try container.decodeIfPresent(Bool.self, forKey: .lines),
            warm: try container.decodeIfPresent(Bool.self, forKey: .warm),
            formula: try container.decodeIfPresent(String.self, forKey: .formula),
            formulas: try container.decodeIfPresent(String.self, forKey: .formulas),
            tidy: try container.decodeIfPresent(Bool.self, forKey: .tidy),
            vlm: try container.decodeIfPresent(String.self, forKey: .vlm),
            task: try container.decodeIfPresent(String.self, forKey: .task),
            seconds: try container.decodeIfPresent(Double.self, forKey: .seconds),
            pressure: try? container.decodeIfPresent(MemoryPressure.self, forKey: .pressure)
        )
    }
}
