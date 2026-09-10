import Foundation

/// Dedicated lexical support for indentation-based web templates and CoffeeScript.
/// These rules supplement the general tokenizer without pretending that HTML or
/// JavaScript parsers understand Haml/CoffeeScript grammar.
enum TemplateSyntaxEngine {
    static let extensions: Set<String> = ["haml", "chaml", "coffeehaml", "lithaml", "coffee", "litcoffee"]

    static func tokenize(_ text: String, extension ext: String, range: NSRange) -> [Token] {
        let template = ["haml", "chaml", "coffeehaml", "lithaml"].contains(ext)
        var rules: [(TokenScope, String)] = [
            (.comment, #"(?s)###.*?###"#),
            (.string, #"(?s)""".*?"""|'''.*?'''"#),
            (.string, #""(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'"#),
        ]
        if template {
            rules += [
                (.comment, #"(?m)^\s*(?:-#|/).*$"#),
                (.tag, #"%[A-Za-z][\w:-]*"#),
                (.attribute, #"[.#][A-Za-z_][\w-]*"#),
                (.attribute, #"\b[\w:-]+(?=\s*[:=])"#),
                (.preprocessor, #"(?m)^\s*:[a-zA-Z]+"#),
                (.operator, #"(?m)^\s*(?:!=|=|-)(?=\s|\w)"#),
            ]
        } else {
            rules.append((.comment, #"(?m)#(?!\{).*$"#))
        }
        rules += [
            (.keyword, #"\b(?:if|else|unless|then|for|in|of|by|when|while|until|loop|switch|when|class|extends|super|return|yield|try|catch|finally|throw|new|do|and|or|is|isnt|not|instanceof|typeof|delete|import|export|from|as|await)\b"#),
            (.constantLanguage, #"\b(?:true|false|yes|no|on|off|null|undefined|nil)\b"#),
            (.variableInstance, #"@[A-Za-z_]\w*"#),
            (.number, #"\b(?:0[xX][\da-fA-F]+|\d+(?:\.\d+)?)\b"#),
            (.operator, #"[-=]>|\?\.|\?=|===?|!==?|[+*/<>-]=?"#),
        ]
        var covered = IndexSet()
        var tokens: [Token] = []
        for (scope, pattern) in rules {
            guard let expression = try? NSRegularExpression(pattern: pattern) else { continue }
            for match in expression.matches(in: text, range: range) where match.range.length > 0 {
                let indices = match.range.location..<NSMaxRange(match.range)
                guard covered.intersection(IndexSet(integersIn: indices)).isEmpty else { continue }
                covered.insert(integersIn: indices)
                tokens.append(Token(range: match.range, scope: scope))
            }
        }
        return tokens.sorted { $0.range.location < $1.range.location }
    }
}
