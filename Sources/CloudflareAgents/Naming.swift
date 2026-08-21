import Foundation

/// Convert an Agent class / binding name to its URL slug.
///
/// Mirrors `camelCaseToKebabCase` in `cloudflare/agents` `packages/agents/src/utils.ts`,
/// including the all-caps binding path (`COUNTER_DO` → `counter-do`).
public func camelCaseToKebabCase(_ input: String) -> String {
    if !input.isEmpty,
       input == input.uppercased(),
       input != input.lowercased()
    {
        return input.lowercased().replacingOccurrences(of: "_", with: "-")
    }

    var kebabified = ""
    for char in input {
        if char.isUppercase {
            kebabified += "-"
            kebabified += char.lowercased()
        } else {
            kebabified.append(char)
        }
    }
    if kebabified.hasPrefix("-") {
        kebabified.removeFirst()
    }
    return kebabified
        .replacingOccurrences(of: "_", with: "-")
        .replacingOccurrences(of: "-$", with: "", options: .regularExpression)
}

/// Percent-encode a string the way JavaScript `encodeURIComponent` does.
///
/// Unescaped characters: `A-Z a-z 0-9 - _ . ! ~ * ' ( )`
public func encodeURIComponent(_ string: String) -> String {
    let unescaped = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()")
    var result = ""
    for scalar in string.unicodeScalars {
        if unescaped.contains(Character(scalar)) {
            result.append(Character(scalar))
        } else {
            for byte in String(scalar).utf8 {
                result.append(String(format: "%%%02X", byte))
            }
        }
    }
    return result
}
