// Sign-in codes and the Copy code button (docs/design/notify.md, part 2).
//
// The scan is a pure function over the notification's title and text; the copy
// only happens when the person clicks Copy code, marks the pasteboard item as
// concealed/transient and clears it again after 90 s if it is still there.

import AppKit
import Foundation

enum NotifyCode {

    /// A candidate must sit within this many characters of its keyword.
    static let keywordDistance = 32

    /// The code in a notification, or nil. 4–8 digits, or 6–8 alphanumerics
    /// with at least two digits, next to a sign-in keyword, and never part of a
    /// longer number, a date/time, an amount or a phone number.
    static func find(title: String?, text: String?) -> String? {
        let field = [title, text]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        guard !field.isEmpty else { return nil }
        let keywords = keywordRanges(field)
        guard !keywords.isEmpty else { return nil }
        for token in tokens(field) {
            guard validLength(token.value), token.digits >= (token.isAllDigits ? 0 : 2) else { continue }
            guard !token.isAllDigits || token.value.count >= 4 else { continue }
            guard !adjacentNumberOrDate(field, token.range) else { continue }
            guard !looksLikeAmount(field, token.range) else { continue }
            guard nearKeyword(token.range, keywords) else { continue }
            return token.value
        }
        return nil
    }

    // MARK: candidates

    private struct Token {
        let value: String
        let range: NSRange
        let digits: Int
        let isAllDigits: Bool
    }

    private static func tokens(_ field: String) -> [Token] {
        let regex = try! NSRegularExpression(pattern: "[A-Za-z0-9]+")
        let ns = field as NSString
        return regex.matches(in: field, range: NSRange(location: 0, length: ns.length)).compactMap { match in
            let value = ns.substring(with: match.range)
            let digits = value.reduce(0) { $0 + ($1.isNumber ? 1 : 0) }
            let allDigits = digits == value.count
            let length = value.count
            guard allDigits ? (4...8).contains(length) : (6...8).contains(length) else { return nil }
            return Token(value: value, range: match.range, digits: digits, isAllDigits: allDigits)
        }
    }

    private static func validLength(_ value: String) -> Bool {
        value.allSatisfy { $0.isASCII && ($0.isNumber || $0.isLetter) }
    }

    /// `1234-5678`, `2026/10/20`, `99.99`: a digit on either side of a separator
    /// means this run belongs to a bigger number or a date, not a code.
    private static func adjacentNumberOrDate(_ field: String, _ range: NSRange) -> Bool {
        let ns = field as NSString
        let separators = Set(["-", "/", ".", ":", ","])
        let before = character(ns, range.location - 1)
        let after = character(ns, range.location + range.length)
        if let before, separators.contains(before) { return true }
        if let after, separators.contains(after) { return true }
        if before.map(isDigit) == true || after.map(isDigit) == true { return true }
        // A phone number's leading plus.
        if before == "+" { return true }
        return false
    }

    /// Money and percentages: `$1,299`, `R$ 1299`, `25%`.
    private static func looksLikeAmount(_ field: String, _ range: NSRange) -> Bool {
        let ns = field as NSString
        var before = range.location - 1
        while let ch = character(ns, before), ch == " " || ch == "\t" || ch == "\u{00a0}" {
            before -= 1
        }
        if let ch = character(ns, before), ch == "$" || ch == "€" || ch == "£" { return true }
        if let ch = character(ns, range.location + range.length), ch == "%" { return true }
        return false
    }

    private static func character(_ ns: NSString, _ index: Int) -> String? {
        guard index >= 0, index < ns.length else { return nil }
        return ns.substring(with: NSRange(location: index, length: 1))
    }

    private static func isDigit(_ ch: String) -> Bool {
        ch.rangeOfCharacter(from: .decimalDigits) != nil
    }

    private static func isAlphanumeric(_ ch: String) -> Bool {
        ch.rangeOfCharacter(from: .alphanumerics) != nil
    }

    // MARK: keywords

    /// The keyword ranges, lowercased. "senha"/"password" only count when the
    /// field also says "code"/"código" (a lone "password" is a field label).
    private static func keywordRanges(_ field: String) -> [NSRange] {
        let lower = field.lowercased()
        let strong = ["code", "código", "codigo", "verification", "verificação", "verificacao",
                      "passcode", "otp", "pin"]
        var words = strong
        let hasCode = strong.prefix(3).contains { lower.contains($0) }
        if hasCode { words += ["senha", "password"] }
        var ranges: [NSRange] = []
        let ns = lower as NSString
        for word in words {
            var start = 0
            while start < ns.length {
                let found = ns.range(of: word, options: [], range: NSRange(location: start, length: ns.length - start))
                if found.location == NSNotFound { break }
                if isWordBoundary(ns, found) { ranges.append(found) }
                start = found.location + max(found.length, 1)
            }
        }
        return ranges
    }

    private static func isWordBoundary(_ ns: NSString, _ range: NSRange) -> Bool {
        if let before = character(ns, range.location - 1), isAlphanumeric(before) { return false }
        if let after = character(ns, range.location + range.length), isAlphanumeric(after) { return false }
        return true
    }

    private static func nearKeyword(_ range: NSRange, _ keywords: [NSRange]) -> Bool {
        let start = range.location
        let end = range.location + range.length
        return keywords.contains { keyword in
            let gap: Int
            if keyword.location + keyword.length <= start {
                gap = start - (keyword.location + keyword.length)
            } else if end <= keyword.location {
                gap = keyword.location - end
            } else {
                gap = 0
            }
            return gap <= keywordDistance
        }
    }
}

// MARK: - Clipboard

/// The pasteboard surface the copy uses; tests inject a private pasteboard and
/// a fake scheduler so the person's own clipboard is never touched.
protocol CodePasteboard: AnyObject {
    var changeCount: Int { get }
    func writeConcealed(_ text: String)
    func clear()
}

final class SystemCodePasteboard: CodePasteboard {
    static let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    static let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    private let pasteboard: NSPasteboard

    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    var changeCount: Int { pasteboard.changeCount }

    /// The value plus the two marker types clipboard managers honour.
    func writeConcealed(_ text: String) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        pasteboard.setData(Data(), forType: Self.concealed)
        pasteboard.setData(Data(), forType: Self.transient)
    }

    func clear() {
        pasteboard.clearContents()
    }
}

/// Copy code on click, then clear it after 90 s if the pasteboard still holds
/// that same item (a changeCount check, so a later copy is never destroyed).
final class CodeCopy {
    static let lifetime: TimeInterval = 90

    private let pasteboard: CodePasteboard
    private let schedule: (TimeInterval, @escaping () -> Void) -> Void

    init(pasteboard: CodePasteboard,
         schedule: @escaping (TimeInterval, @escaping () -> Void) -> Void = CodeCopy.after) {
        self.pasteboard = pasteboard
        self.schedule = schedule
    }

    static func after(_ delay: TimeInterval, _ block: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: block)
    }

    @discardableResult
    func copy(_ code: String) -> Int {
        pasteboard.writeConcealed(code)
        let written = pasteboard.changeCount
        schedule(Self.lifetime) { [weak pasteboard] in
            guard let pasteboard, pasteboard.changeCount == written else { return }
            pasteboard.clear()
        }
        return code.count
    }
}
