//! Built-in JavaScript / TypeScript and Python names offered by completion.
const std = @import("std");
const js = @import("../../syntax/lib/js.zig");
const python = @import("../../syntax/lib/python.zig");

pub const python_keywords = python.keyword_list ++ python.constant_list;
pub const python_types = python.builtin_type_list;
pub const python_functions = python.builtin_function_list;

pub const keywords = js.keyword_list ++ js.contextual_keyword_list ++ js.constant_list;
pub const types = js.builtin_type_list ++ [_][]const u8{
    "Record",      "Partial",    "Required",   "Readonly", "Pick",  "Omit",          "Exclude", "Extract",
    "NonNullable", "ReturnType", "Parameters", "Awaited",  "Array", "ReadonlyArray",
};

pub const globals = [_][]const u8{
    "console",       "window",  "document",        "globalThis",         "Math",               "JSON",
    "Object",        "Array",   "String",          "Number",             "Boolean",            "Symbol",
    "BigInt",        "Promise", "Map",             "Set",                "WeakMap",            "WeakSet",
    "Date",          "RegExp",  "Error",           "TypeError",          "RangeError",         "parseInt",
    "parseFloat",    "isNaN",   "isFinite",        "setTimeout",         "clearTimeout",       "setInterval",
    "clearInterval", "fetch",   "structuredClone", "queueMicrotask",     "require",            "module",
    "exports",       "process", "localStorage",    "encodeURIComponent", "decodeURIComponent",
};

/// Members offered after `<object>.` for well-known objects.
pub fn membersOf(object: []const u8) []const []const u8 {
    return known_members.get(object) orelse &.{};
}

/// Members common to arrays, strings, promises and maps, offered after any `.`.
pub const common_members = [_][]const u8{
    "length",    "push",       "pop",         "shift",            "unshift",             "map",
    "filter",    "reduce",     "forEach",     "find",             "findIndex",           "some",
    "every",     "includes",   "indexOf",     "slice",            "splice",              "concat",
    "join",      "sort",       "reverse",     "flat",             "flatMap",             "at",
    "fill",      "keys",       "values",      "entries",          "then",                "catch",
    "finally",   "toString",   "split",       "trim",             "startsWith",          "endsWith",
    "replace",   "replaceAll", "toUpperCase", "toLowerCase",      "padStart",            "padEnd",
    "substring", "match",      "get",         "set",              "has",                 "delete",
    "clear",     "size",       "add",         "addEventListener", "removeEventListener",
};

const known_members = std.StaticStringMap([]const []const u8).initComptime(.{
    .{ "console", &[_][]const u8{ "log", "error", "warn", "info", "debug", "table", "time", "timeEnd", "trace", "assert", "group", "groupEnd", "count", "dir" } },
    .{ "Math", &[_][]const u8{ "abs", "ceil", "floor", "round", "max", "min", "pow", "sqrt", "random", "sign", "trunc", "PI", "E", "log", "sin", "cos", "tan", "atan2", "hypot" } },
    .{ "JSON", &[_][]const u8{ "parse", "stringify" } },
    .{ "Object", &[_][]const u8{ "keys", "values", "entries", "assign", "freeze", "fromEntries", "create", "defineProperty", "getPrototypeOf", "hasOwn" } },
    .{ "Array", &[_][]const u8{ "isArray", "from", "of" } },
    .{ "Promise", &[_][]const u8{ "all", "allSettled", "any", "race", "resolve", "reject" } },
    .{ "Number", &[_][]const u8{ "isInteger", "isFinite", "isNaN", "parseFloat", "parseInt", "MAX_SAFE_INTEGER", "MIN_SAFE_INTEGER", "EPSILON" } },
    .{ "String", &[_][]const u8{ "fromCharCode", "raw" } },
    .{ "document", &[_][]const u8{ "getElementById", "querySelector", "querySelectorAll", "createElement", "addEventListener", "body", "head", "title" } },
});
