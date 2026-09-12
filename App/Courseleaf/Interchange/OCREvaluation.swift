import Foundation

/// Scoring for the OCR evaluation corpus (docs/VALIDATION.md, A15): character
/// error rate and word error rate as Levenshtein distance over the reference
/// length. Pure Swift so the metric itself is portable and unit-tested; the
/// recognizer under test is `VisionTextRecognizer`.
///
/// Status: printed-text samples are rendered synthetically by
/// `InterchangeOCRTests` on the simulator. **Handwriting evaluation is device
/// work** (real Pencil samples: neat, cursive, small, mixed equations,
/// low-quality photos) and is pending until a physical iPad is available.
enum OCREvaluation {
    struct Normalization: Hashable, Sendable {
        var caseInsensitive = true
        var collapseWhitespace = true
        var stripPunctuation = true
        init(caseInsensitive: Bool = true, collapseWhitespace: Bool = true, stripPunctuation: Bool = true) {
            self.caseInsensitive = caseInsensitive; self.collapseWhitespace = collapseWhitespace; self.stripPunctuation = stripPunctuation
        }
        static let `default` = Normalization()
        static let exact = Normalization(caseInsensitive: false, collapseWhitespace: false, stripPunctuation: false)
    }

    struct Score: Hashable, Sendable, CustomStringConvertible {
        var characterErrorRate: Double
        var wordErrorRate: Double
        var characterEdits: Int
        var wordEdits: Int
        var referenceCharacters: Int
        var referenceWords: Int

        var description: String {
            String(format: "CER %.3f (%d/%d)  WER %.3f (%d/%d)", characterErrorRate, characterEdits, referenceCharacters,
                   wordErrorRate, wordEdits, referenceWords)
        }
    }

    /// Levenshtein edit distance (insertions, deletions, substitutions) between two sequences.
    static func levenshtein<T: Equatable>(_ a: [T], _ b: [T]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }

    static func normalize(_ text: String, _ normalization: Normalization) -> String {
        var s = text
        if normalization.caseInsensitive { s = s.lowercased() }
        if normalization.stripPunctuation {
            s = String(s.unicodeScalars.filter { !CharacterSet.punctuationCharacters.contains($0) && !CharacterSet.symbols.contains($0) })
        }
        if normalization.collapseWhitespace {
            s = s.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        }
        return s
    }

    static func words(_ text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).map(String.init)
    }

    /// CER = character edits / reference characters; WER = word edits / reference words.
    /// An empty reference scores 0 when the hypothesis is empty too, else 1.
    static func score(reference: String, hypothesis: String, normalization: Normalization = .default) -> Score {
        let ref = normalize(reference, normalization)
        let hyp = normalize(hypothesis, normalization)
        let refChars = Array(ref), hypChars = Array(hyp)
        let refWords = words(ref), hypWords = words(hyp)
        let charEdits = levenshtein(refChars, hypChars)
        let wordEdits = levenshtein(refWords, hypWords)
        let cer = refChars.isEmpty ? (hypChars.isEmpty ? 0 : 1) : Double(charEdits) / Double(refChars.count)
        let wer = refWords.isEmpty ? (hypWords.isEmpty ? 0 : 1) : Double(wordEdits) / Double(refWords.count)
        return Score(characterErrorRate: cer, wordErrorRate: wer, characterEdits: charEdits, wordEdits: wordEdits,
                     referenceCharacters: refChars.count, referenceWords: refWords.count)
    }

    static func characterErrorRate(reference: String, hypothesis: String, normalization: Normalization = .default) -> Double {
        score(reference: reference, hypothesis: hypothesis, normalization: normalization).characterErrorRate
    }

    static func wordErrorRate(reference: String, hypothesis: String, normalization: Normalization = .default) -> Double {
        score(reference: reference, hypothesis: hypothesis, normalization: normalization).wordErrorRate
    }

    /// Recognized lines joined top to bottom, left to right, into one transcript.
    static func transcript(lines: [(text: String, minY: Double, minX: Double)]) -> String {
        lines.sorted { a, b in
            if abs(a.minY - b.minY) > 4 { return a.minY < b.minY }
            return a.minX < b.minX
        }.map(\.text).joined(separator: "\n")
    }

    /// Aggregate over several samples, weighted by reference length.
    static func aggregate(_ scores: [Score]) -> Score {
        let chars = scores.reduce(0) { $0 + $1.referenceCharacters }
        let wordsCount = scores.reduce(0) { $0 + $1.referenceWords }
        let charEdits = scores.reduce(0) { $0 + $1.characterEdits }
        let wordEdits = scores.reduce(0) { $0 + $1.wordEdits }
        return Score(characterErrorRate: chars == 0 ? 0 : Double(charEdits) / Double(chars),
                     wordErrorRate: wordsCount == 0 ? 0 : Double(wordEdits) / Double(wordsCount),
                     characterEdits: charEdits, wordEdits: wordEdits, referenceCharacters: chars, referenceWords: wordsCount)
    }
}
