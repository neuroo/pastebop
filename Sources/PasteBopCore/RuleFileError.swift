//
//  RuleFileError.swift
//  PasteBopCore
//

import Foundation

extension RuleFile {

    public struct ParseError: LocalizedError, Equatable, Sendable {
        public let line: Int
        public let reason: Reason

        public enum Reason: Equatable, Sendable {
            case unexpectedIndentation
            case unknownKey(String)
            case missingVersion
            case unsupportedVersion(Int)
            case badVersion(String)
            case ruleOutsideRulesSection
            case missingColon
            case badScalar(String)
            case emptyRange(String)
            case emptySequence
            case rangeInSequence(String)
            case asciiScalar(String)
            case tooManyRules
            case fileTooLarge(bytes: Int)
            case sequenceTooLong(String)
            case replacementTooLong
            case duplicate(String, firstSeenOnLine: Int)
            case unquotedValue(String)
            case unterminatedString
            case badEscape(String)
            case trailingText(String)
        }

        public var errorDescription: String? {
            "Line \(line): \(explanation)"
        }

        private var explanation: String {
            switch reason {
            case .unexpectedIndentation:
                "unexpected indentation. Rules are indented under \"rules:\"."
            case .unknownKey(let key):
                "unknown setting \"\(key)\". Expected \"version\" or \"rules\"."
            case .missingVersion:
                "the file must start with \"version: \(Self.currentVersionText)\"."
            case .unsupportedVersion(let version):
                "this build reads version \(Self.currentVersionText) files, not \(version)."
            case .badVersion(let text):
                "\"\(text)\" is not a version number."
            case .ruleOutsideRulesSection:
                "rules must appear under \"rules:\"."
            case .missingColon:
                "expected \"U+XXXX: \"replacement\"\"."
            case .badScalar(let key):
                "\"\(key)\" is not a scalar. Use U+2014, or U+E0000..U+E007F for a range."
            case .emptyRange(let key):
                "\"\(key)\" ends before it starts."
            case .emptySequence:
                "the key is empty. Write a scalar, a range, or a substring to match."
            case .rangeInSequence(let word):
                "\"\(word)\" is a range, which cannot be part of a substring."
            case .asciiScalar(let key):
                "\"\(key)\" is below U+00A0. PasteBop never rewrites an ASCII character "
                    + "on its own; use a substring."
            case .fileTooLarge(let bytes):
                "the rules file is \(bytes / 1024) KB; the limit is \(RuleFile.Limits.fileBytes / 1024) KB."
            case .tooManyRules:
                "too many rules; the limit is \(Limits.rules)."
            case .sequenceTooLong(let key):
                "\"\(key)\" is longer than \(Limits.sequenceScalars) characters."
            case .replacementTooLong:
                "the replacement is longer than \(Limits.replacementScalars) characters."
            case .duplicate(let key, let first):
                "\"\(key)\" was already set on line \(first)."
            case .unquotedValue(let text):
                "the replacement must be quoted. Write \"\(text)\" rather than \(text)."
            case .unterminatedString:
                "the replacement is missing its closing quote."
            case .badEscape(let escape):
                "\\\(escape) is not a recognised escape."
            case .trailingText(let text):
                "unexpected \"\(text)\" after the replacement. Comments start with #."
            }
        }

        private static var currentVersionText: String { String(RuleFile.currentVersion) }
    }
}
