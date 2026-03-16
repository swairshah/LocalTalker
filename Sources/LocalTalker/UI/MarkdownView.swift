import SwiftUI

// MARK: - Markdown Renderer

/// Lightweight markdown renderer for chat messages.
/// Supports: code blocks (with syntax highlighting), inline code,
/// bold, italic, headers, lists, and links.
struct MarkdownView: View {
    let text: String
    let opacity: Double

    init(_ text: String, opacity: Double = 0.85) {
        self.text = text
        self.opacity = opacity
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .code(let lang, let code):
                    CodeBlockView(language: lang, code: code)
                case .text(let content):
                    if !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        richText(content)
                    }
                }
            }
        }
    }

    // MARK: - Block parsing

    private enum Block {
        case text(String)
        case code(language: String?, code: String)
    }

    private var blocks: [Block] {
        var result: [Block] = []
        let lines = text.components(separatedBy: "\n")
        var i = 0
        var textBuffer = ""

        while i < lines.count {
            let line = lines[i]

            if line.hasPrefix("```") {
                // Flush text buffer
                if !textBuffer.isEmpty {
                    result.append(.text(textBuffer))
                    textBuffer = ""
                }

                // Extract language hint
                let lang = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                let language = lang.isEmpty ? nil : lang

                // Collect code lines until closing ```
                var codeLines: [String] = []
                i += 1
                while i < lines.count && !lines[i].hasPrefix("```") {
                    codeLines.append(lines[i])
                    i += 1
                }
                // Skip closing ```
                if i < lines.count { i += 1 }

                result.append(.code(language: language, code: codeLines.joined(separator: "\n")))
            } else {
                textBuffer += (textBuffer.isEmpty ? "" : "\n") + line
                i += 1
            }
        }

        if !textBuffer.isEmpty {
            result.append(.text(textBuffer))
        }

        return result
    }

    // MARK: - Rich text (inline markdown)

    @ViewBuilder
    private func richText(_ content: String) -> some View {
        let lines = content.components(separatedBy: "\n")
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty {
                    Spacer().frame(height: 4)
                } else if trimmed.hasPrefix("### ") {
                    inlineMarkdown(String(trimmed.dropFirst(4)))
                        .font(.system(size: 13, weight: .semibold))
                } else if trimmed.hasPrefix("## ") {
                    inlineMarkdown(String(trimmed.dropFirst(3)))
                        .font(.system(size: 14, weight: .bold))
                } else if trimmed.hasPrefix("# ") {
                    inlineMarkdown(String(trimmed.dropFirst(2)))
                        .font(.system(size: 15, weight: .bold))
                } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("•")
                            .font(.system(size: 13))
                            .foregroundStyle(Color.white.opacity(opacity * 0.5))
                        inlineMarkdown(String(trimmed.dropFirst(2)))
                            .font(.system(size: 13))
                    }
                } else if let match = trimmed.range(of: #"^\d+\.\s"#, options: .regularExpression) {
                    let num = String(trimmed[match])
                    let rest = String(trimmed[match.upperBound...])
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(num)
                            .font(.system(size: 13))
                            .foregroundStyle(Color.white.opacity(opacity * 0.5))
                        inlineMarkdown(rest)
                            .font(.system(size: 13))
                    }
                } else {
                    inlineMarkdown(trimmed)
                        .font(.system(size: 13))
                }
            }
        }
    }

    /// Parse inline markdown (bold, italic, inline code) into a styled Text.
    private func inlineMarkdown(_ str: String) -> Text {
        var result = Text("")
        var remaining = str[str.startIndex...]

        while !remaining.isEmpty {
            // Inline code: `...`
            if remaining.hasPrefix("`"),
               let endIdx = remaining.dropFirst().firstIndex(of: "`") {
                let code = remaining[remaining.index(after: remaining.startIndex)..<endIdx]
                result = result + Text(String(code))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(Color(red: 0.85, green: 0.75, blue: 0.55))
                remaining = remaining[remaining.index(after: endIdx)...]
                continue
            }

            // Bold: **...**
            if remaining.hasPrefix("**"),
               let endRange = remaining.dropFirst(2).range(of: "**") {
                let bold = remaining[remaining.index(remaining.startIndex, offsetBy: 2)..<endRange.lowerBound]
                result = result + Text(String(bold))
                    .bold()
                    .foregroundColor(Color.white.opacity(opacity))
                remaining = remaining[endRange.upperBound...]
                continue
            }

            // Italic: *...*  (but not **)
            if remaining.hasPrefix("*") && !remaining.hasPrefix("**"),
               let endIdx = remaining.dropFirst().firstIndex(of: "*") {
                let italic = remaining[remaining.index(after: remaining.startIndex)..<endIdx]
                result = result + Text(String(italic))
                    .italic()
                    .foregroundColor(Color.white.opacity(opacity))
                remaining = remaining[remaining.index(after: endIdx)...]
                continue
            }

            // Plain character
            let char = remaining[remaining.startIndex]
            result = result + Text(String(char))
                .foregroundColor(Color.white.opacity(opacity))
            remaining = remaining[remaining.index(after: remaining.startIndex)...]
        }

        return result
    }
}

// MARK: - Code Block View

private struct CodeBlockView: View {
    let language: String?
    let code: String
    @State private var copied = false

    private static let bgColor = Color(red: 0.06, green: 0.06, blue: 0.07)
    private static let borderColor = Color.white.opacity(0.06)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header bar
            HStack(spacing: 6) {
                if let lang = language, !lang.isEmpty {
                    Text(lang)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.35))
                }
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 9))
                        Text(copied ? "Copied" : "Copy")
                            .font(.system(size: 10))
                    }
                    .foregroundStyle(Color.white.opacity(copied ? 0.5 : 0.3))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.white.opacity(0.02))

            Divider().overlay(Color.white.opacity(0.04))

            // Code content with syntax highlighting
            ScrollView(.horizontal, showsIndicators: false) {
                highlightedCode
                    .padding(10)
            }
        }
        .background(Self.bgColor)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Self.borderColor, lineWidth: 1)
        )
    }

    @ViewBuilder
    private var highlightedCode: some View {
        let lines = code.components(separatedBy: "\n")
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(lines.enumerated()), id: \.offset) { idx, line in
                HStack(alignment: .top, spacing: 10) {
                    // Line number
                    Text("\(idx + 1)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Color.white.opacity(0.15))
                        .frame(width: 24, alignment: .trailing)

                    // Highlighted line
                    highlightLine(line)
                }
            }
        }
        .textSelection(.enabled)
    }

    private func highlightLine(_ line: String) -> Text {
        let lang = language?.lowercased() ?? ""
        return SyntaxHighlighter.highlight(line, language: lang)
    }
}

// MARK: - Syntax Highlighter

private enum SyntaxHighlighter {
    // Colors matching a dark-theme palette
    static let keyword   = Color(red: 0.78, green: 0.50, blue: 0.85)  // purple
    static let string    = Color(red: 0.60, green: 0.80, blue: 0.55)  // green
    static let comment   = Color.white.opacity(0.30)                    // dim
    static let number    = Color(red: 0.85, green: 0.70, blue: 0.45)  // orange
    static let type      = Color(red: 0.55, green: 0.75, blue: 0.90)  // blue
    static let plain     = Color.white.opacity(0.75)
    static let punct     = Color.white.opacity(0.45)

    static let keywords: Set<String> = [
        // Swift / C / general
        "func", "var", "let", "if", "else", "for", "while", "return", "import",
        "class", "struct", "enum", "protocol", "extension", "guard", "switch",
        "case", "break", "continue", "do", "try", "catch", "throw", "throws",
        "async", "await", "self", "Self", "super", "init", "deinit", "static",
        "private", "public", "internal", "open", "fileprivate", "override",
        "true", "false", "nil", "in", "is", "as", "where", "typealias",
        // Python
        "def", "class", "from", "import", "return", "if", "elif", "else",
        "for", "while", "with", "as", "try", "except", "finally", "raise",
        "yield", "lambda", "pass", "del", "and", "or", "not", "True",
        "False", "None", "print", "self", "global", "nonlocal", "assert",
        // JS / TS
        "function", "const", "var", "let", "if", "else", "for", "while",
        "return", "class", "extends", "new", "this", "super", "import",
        "export", "default", "from", "of", "typeof", "instanceof",
        "async", "await", "try", "catch", "throw", "finally",
        "null", "undefined", "true", "false", "void",
        // Rust
        "fn", "let", "mut", "pub", "use", "mod", "struct", "enum", "impl",
        "trait", "match", "loop", "move", "ref", "crate", "extern",
        // Bash
        "echo", "export", "source", "alias", "cd", "ls", "grep", "awk",
        "sed", "find", "xargs", "sudo", "chmod", "chown", "mkdir", "rm",
        "cp", "mv", "cat", "head", "tail", "sort", "uniq", "wc", "then",
        "fi", "done", "do",
    ]

    static let types: Set<String> = [
        "String", "Int", "Double", "Float", "Bool", "Array", "Dictionary",
        "Set", "Optional", "Result", "URL", "Data", "Date", "Error",
        "View", "some", "Any", "AnyObject", "Void", "Never",
        "Task", "MainActor", "ObservableObject", "Published", "State",
        "Binding", "ObservedObject", "EnvironmentObject", "Environment",
    ]

    static func highlight(_ line: String, language: String) -> Text {
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        // Full-line comment
        if trimmed.hasPrefix("//") || trimmed.hasPrefix("#") && language != "markdown" {
            return Text(line).font(.system(size: 11, design: .monospaced)).foregroundColor(comment)
        }

        var result = Text("")
        let tokens = tokenize(line)

        for token in tokens {
            let styled: Text
            switch token.kind {
            case .keyword:
                styled = Text(token.text).foregroundColor(keyword)
            case .type:
                styled = Text(token.text).foregroundColor(type)
            case .string:
                styled = Text(token.text).foregroundColor(string)
            case .number:
                styled = Text(token.text).foregroundColor(number)
            case .comment:
                styled = Text(token.text).foregroundColor(comment)
            case .punctuation:
                styled = Text(token.text).foregroundColor(punct)
            case .plain:
                styled = Text(token.text).foregroundColor(plain)
            case .whitespace:
                styled = Text(token.text)
            }
            result = result + styled.font(.system(size: 11, design: .monospaced))
        }

        return result
    }

    // MARK: - Tokenizer

    enum TokenKind {
        case keyword, type, string, number, comment, punctuation, plain, whitespace
    }

    struct Token {
        let text: String
        let kind: TokenKind
    }

    static func tokenize(_ line: String) -> [Token] {
        var tokens: [Token] = []
        var i = line.startIndex

        while i < line.endIndex {
            let ch = line[i]

            // Whitespace
            if ch.isWhitespace {
                var end = i
                while end < line.endIndex && line[end].isWhitespace { end = line.index(after: end) }
                tokens.append(Token(text: String(line[i..<end]), kind: .whitespace))
                i = end
                continue
            }

            // Line comment
            if ch == "/" && line.index(after: i) < line.endIndex && line[line.index(after: i)] == "/" {
                tokens.append(Token(text: String(line[i...]), kind: .comment))
                return tokens
            }
            if ch == "#" {
                // Shell-style comment (but not #include)
                let rest = String(line[i...])
                if rest.hasPrefix("#!") || rest.hasPrefix("#include") || rest.hasPrefix("#import") || rest.hasPrefix("#define") || rest.hasPrefix("#if") {
                    // preprocessor — treat as keyword
                } else if i == line.startIndex || line[line.index(before: i)].isWhitespace {
                    tokens.append(Token(text: String(line[i...]), kind: .comment))
                    return tokens
                }
            }

            // String literals
            if ch == "\"" || ch == "'" {
                let quote = ch
                var end = line.index(after: i)
                while end < line.endIndex {
                    if line[end] == "\\" {
                        end = line.index(after: end)
                        if end < line.endIndex { end = line.index(after: end) }
                        continue
                    }
                    if line[end] == quote {
                        end = line.index(after: end)
                        break
                    }
                    end = line.index(after: end)
                }
                tokens.append(Token(text: String(line[i..<end]), kind: .string))
                i = end
                continue
            }

            // Numbers
            if ch.isNumber || (ch == "." && line.index(after: i) < line.endIndex && line[line.index(after: i)].isNumber) {
                var end = i
                while end < line.endIndex && (line[end].isNumber || line[end] == "." || line[end] == "x" || line[end] == "X"
                       || (line[end] >= "a" && line[end] <= "f") || (line[end] >= "A" && line[end] <= "F")
                       || line[end] == "_") {
                    end = line.index(after: end)
                }
                tokens.append(Token(text: String(line[i..<end]), kind: .number))
                i = end
                continue
            }

            // Words (identifiers / keywords)
            if ch.isLetter || ch == "_" || ch == "@" {
                var end = i
                while end < line.endIndex && (line[end].isLetter || line[end].isNumber || line[end] == "_" || line[end] == "@") {
                    end = line.index(after: end)
                }
                let word = String(line[i..<end])
                let kind: TokenKind
                if keywords.contains(word) {
                    kind = .keyword
                } else if types.contains(word) || (word.first?.isUppercase == true && word.count > 1) {
                    kind = .type
                } else {
                    kind = .plain
                }
                tokens.append(Token(text: word, kind: kind))
                i = end
                continue
            }

            // Punctuation
            tokens.append(Token(text: String(ch), kind: .punctuation))
            i = line.index(after: i)
        }

        return tokens
    }
}
