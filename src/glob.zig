//! Copyright 2026 Andrea Vaccaro
//! Licensed under the Apache License, Version 2.0
//! http://www.apache.org/licenses/LICENSE-2.0
//!
//! This file is part of "Rapto".
//! It contains the implementation of glob matching.

const std = @import("std");

pub fn classify(string: []const u8) enum { any, literal, pattern } {
    if (string.len == 0) return .literal;

    var all_stars = true;
    var has_special = false;

    for (string) |c| switch (c) {
        '*' => has_special = true,
        '?', '[', '\\' => {
            all_stars = false;
            has_special = true;
        },
        else => all_stars = false,
    };

    if (all_stars) return .any;
    return if (has_special) .pattern else .literal;
}

/// Glob matching related to https://github.com/gcc-mirror/gcc/blob/master/libiberty/fnmatch.c.
pub fn match(pattern: []const u8, string: []const u8) bool {
    var p: u64 = 0;
    var n: u64 = 0;
    var c: u8 = 0;

    while (p < pattern.len) {
        c = pattern[p];
        p += 1;

        switch (c) {
            '?' => {
                if (n >= string.len) return false;
            },
            '\\' => {
                c = if (p < pattern.len) pattern[p] else 0;
                p += 1;
                if (n >= string.len or string[n] != c) return false;
            },
            '*' => {
                c = if (p < pattern.len) pattern[p] else 0;
                if (p < pattern.len) p += 1;
                while (c == '?' or c == '*') {
                    if (c == '?') {
                        if (n >= string.len) return false;
                        n += 1;
                    }

                    c = if (p < pattern.len) pattern[p] else 0;
                    if (p < pattern.len) p += 1;
                }

                if (c == 0 and p >= pattern.len) return true;

                {
                    const c1: u8 = if (c == '\\' and p < pattern.len) pattern[p] else c;

                    p -= 1;

                    if (c == '[') {
                        while (n < string.len) : (n += 1) {
                            if (match(pattern[p..], string[n..])) return true;
                        }
                        return false;
                    }

                    var start = n;
                    while (std.mem.findScalarPos(u8, string, start, c1)) |idx| {
                        if (match(pattern[p..], string[idx..])) return true;
                        start = idx + 1;
                    }
                    return false;
                }
            },
            '[' => {
                if (n >= string.len) return false;

                var negate = false;
                if (p < pattern.len and (pattern[p] == '!' or pattern[p] == '^')) {
                    negate = true;
                    p += 1;
                }

                if (p >= pattern.len) return false;
                c = pattern[p];
                p += 1;

                var matched = false;
                while (true) {
                    var cstart = c;
                    var cend = c;

                    if (c == '\\') {
                        cstart = if (p < pattern.len) pattern[p] else 0;
                        cend = cstart;
                        p += 1;
                    }

                    if (p > pattern.len) return false;

                    c = if (p < pattern.len) pattern[p] else 0;
                    p += 1;

                    if (c == '-' and p < pattern.len and pattern[p] != ']') {
                        cend = pattern[p];
                        p += 1;
                        if (cend == '\\') {
                            cend = if (p < pattern.len) pattern[p] else 0;
                            p += 1;
                        }
                        if (p > pattern.len) return false;

                        c = if (p < pattern.len) pattern[p] else 0;
                        p += 1;
                    }

                    if (string[n] >= cstart and string[n] <= cend) {
                        matched = true;
                        break;
                    }
                    if (c == ']') break;
                }

                if (matched) {
                    while (c != ']') {
                        if (p >= pattern.len) return false;
                        c = pattern[p];
                        p += 1;
                        if (c == '\\') p += 1;
                    }
                    if (negate) return false;
                } else {
                    if (!negate) return false;
                }
            },
            else => {
                if (n >= string.len or c != string[n]) return false;
            },
        }

        n += 1;
    }

    return n == string.len;
}

test "classify" {
    try std.testing.expect(classify("") == .literal);
    try std.testing.expect(classify("*") == .any);
    try std.testing.expect(classify("**") == .any);
    try std.testing.expect(classify("***") == .any);
    try std.testing.expect(classify("****") == .any);
    try std.testing.expect(classify("a") == .literal);
    try std.testing.expect(classify("abc") == .literal);
    try std.testing.expect(classify("abc123") == .literal);
    try std.testing.expect(classify("]") == .literal);
    try std.testing.expect(classify("abc]def") == .literal);
    try std.testing.expect(classify("a*b") == .pattern);
    try std.testing.expect(classify("*a") == .pattern);
    try std.testing.expect(classify("a*") == .pattern);
    try std.testing.expect(classify("*a*") == .pattern);
    try std.testing.expect(classify("***?***") == .pattern);
    try std.testing.expect(classify("?") == .pattern);
    try std.testing.expect(classify("a?b") == .pattern);
    try std.testing.expect(classify("*?") == .pattern);
    try std.testing.expect(classify("[") == .pattern);
    try std.testing.expect(classify("[abc]") == .pattern);
    try std.testing.expect(classify("a[bc]d") == .pattern);
    try std.testing.expect(classify("\\") == .pattern);
    try std.testing.expect(classify("a\\b") == .pattern);
    try std.testing.expect(classify("\\*") == .pattern);
    try std.testing.expect(classify("\\?") == .pattern);
    try std.testing.expect(classify("\\[") == .pattern);
}

test "match" {
    try std.testing.expect(match("", ""));
    try std.testing.expect(!match("", "a"));
    try std.testing.expect(!match("a", ""));
    try std.testing.expect(match("abc", "abc"));
    try std.testing.expect(!match("abc", "abd"));
    try std.testing.expect(!match("abc", "ab"));
    try std.testing.expect(!match("abc", "abcd"));
    try std.testing.expect(!match("ABC", "abc"));

    try std.testing.expect(match("a?c", "abc"));
    try std.testing.expect(!match("a?c", "ac"));
    try std.testing.expect(match("?", "a"));
    try std.testing.expect(!match("?", ""));
    try std.testing.expect(match("???", "abc"));
    try std.testing.expect(!match("???", "ab"));

    try std.testing.expect(match("*", ""));
    try std.testing.expect(match("*", "anything"));
    try std.testing.expect(match("**", "anything"));
    try std.testing.expect(match("***", ""));
    try std.testing.expect(match("a*", "a"));
    try std.testing.expect(match("a*", "ab"));
    try std.testing.expect(!match("a*", "b"));
    try std.testing.expect(match("*a", "ba"));
    try std.testing.expect(!match("*a", "b"));
    try std.testing.expect(match("a*b", "aXXb"));
    try std.testing.expect(!match("a*b", "aXXbY"));
    try std.testing.expect(match("a*b*c", "aXXbYYc"));
    try std.testing.expect(!match("a*b*c", "aXXcYYb"));
    try std.testing.expect(match("*.txt", "report.txt"));
    try std.testing.expect(!match("*.txt", "report.md"));
    try std.testing.expect(match("file?.log", "file1.log"));
    try std.testing.expect(!match("file?.log", "file12.log"));

    try std.testing.expect(match("*[0-9]", "abc5"));
    try std.testing.expect(!match("*[0-9]", "abcx"));
    try std.testing.expect(match("*[0-9]*", "abc5def"));

    try std.testing.expect(match("[abc]", "a"));
    try std.testing.expect(match("[abc]", "b"));
    try std.testing.expect(match("[abc]", "c"));
    try std.testing.expect(!match("[abc]", "d"));
    try std.testing.expect(match("[!abc]", "d"));
    try std.testing.expect(!match("[!abc]", "a"));
    try std.testing.expect(match("[^abc]", "d"));
    try std.testing.expect(!match("[^abc]", "a"));

    try std.testing.expect(match("[a-c]", "a"));
    try std.testing.expect(match("[a-c]", "b"));
    try std.testing.expect(match("[a-c]", "c"));
    try std.testing.expect(!match("[a-c]", "d"));
    try std.testing.expect(!match("[c-a]", "a"));
    try std.testing.expect(!match("[c-a]", "b"));
    try std.testing.expect(!match("[c-a]", "c"));

    try std.testing.expect(match("[\\]]", "]"));
    try std.testing.expect(!match("[\\]]", "a"));
    try std.testing.expect(match("[\\-]", "-"));

    try std.testing.expect(!match("[abc", "a"));
    try std.testing.expect(!match("[abc", "d"));

    try std.testing.expect(match("a\\*b", "a*b"));
    try std.testing.expect(!match("a\\*b", "axb"));
    try std.testing.expect(match("a\\?b", "a?b"));
    try std.testing.expect(!match("a\\?b", "axb"));
    try std.testing.expect(!match("a\\", "a"));

    try std.testing.expect(match("a\\*[0-9]", "a*5"));
    try std.testing.expect(!match("a\\*[0-9]", "a*x"));
}
