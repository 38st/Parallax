#!/usr/bin/env python3
"""Census localized Swift literals against Parallax's packaged en/es catalogs.

This is a regression gate, not a translation-quality claim. Known missing keys may
be recorded in an explicit baseline; any newly introduced issue still fails.
"""

from __future__ import annotations

import argparse
import collections
import dataclasses
import json
import pathlib
import plistlib
import re
import sys
import textwrap
from typing import Iterable, Iterator


SWIFTUI_LOCALIZED_CALLS = frozenset(
    {
        "Button",
        "ContentUnavailableView",
        "ControlGroup",
        "DatePicker",
        "DisclosureGroup",
        "Form",
        "GroupBox",
        "Label",
        "LabeledContent",
        "Link",
        "LocalizedStringKey",
        "LocalizedStringResource",
        "Menu",
        "NavigationLink",
        "Picker",
        "ProgressView",
        "Section",
        "SecureField",
        "Stepper",
        "TabView",
        "Text",
        "TextEditor",
        "TextField",
        "Toggle",
        "CommandMenu",
        "WindowGroup",
        "accessibilityHint",
        "accessibilityLabel",
        "alert",
        "confirmationDialog",
        "help",
        "navigationSubtitle",
        "navigationTitle",
    }
)

LOCALIZED_PARAMETER_TYPES = frozenset(
    {
        "LocalizedStringKey",
        "LocalizedStringResource",
        "String.LocalizationValue",
        "String.LocalizationResource",
    }
)

PRINTF_PLACEHOLDER = re.compile(
    r"%(?![%#])(?:(?P<position>\d+)\$)?(?:[-+0 #']*\d*(?:\.\d+)?)?"
    r"(?P<type>@|(?:hh|h|ll|l|q|z|t|j)?[diuoxXfFeEgGaAcCsSp])"
)
PLURAL_REFERENCE = re.compile(r"%#@([A-Za-z_][A-Za-z0-9_]*)@")
PLURAL_METADATA_KEYS = frozenset(
    {"NSStringFormatSpecTypeKey", "NSStringFormatValueTypeKey"}
)
PLURAL_VALUE_TYPE = re.compile(
    r"(?:hh|h|ll|l|q|z|t|j)?[diuoxXfFeEgGaA]"
)


@dataclasses.dataclass(frozen=True)
class SourceOccurrence:
    key: str
    path: str
    line: int
    surface: str


@dataclasses.dataclass(frozen=True)
class DynamicLocalizationOccurrence:
    path: str
    line: int
    expression: str
    ordinal: int


@dataclasses.dataclass(frozen=True)
class UnknownInterpolationOccurrence:
    path: str
    line: int
    expression: str
    ordinal: int


@dataclasses.dataclass(frozen=True)
class LocalizedHelperParameter:
    position: int
    external_label: str | None
    internal_name: str


@dataclasses.dataclass(frozen=True)
class LocalizedHelperDefinition:
    name: str
    parameters: tuple[LocalizedHelperParameter, ...]
    body_start: int | None
    body_end: int | None


@dataclasses.dataclass(frozen=True)
class NormalizedLocalizationKey:
    key: str
    unknown_expressions: tuple[str, ...]


@dataclasses.dataclass(frozen=True)
class SwiftTypeEnvironment:
    variables: dict[str, str]
    members: dict[tuple[str, str], str]


@dataclasses.dataclass(frozen=True)
class FormatPlaceholder:
    position: int | None
    value_type: str


@dataclasses.dataclass(frozen=True)
class Issue:
    code: str
    key: str
    detail: str

    @property
    def fingerprint(self) -> str:
        return f"{self.code}:{self.key}"


@dataclasses.dataclass(frozen=True)
class AuditResult:
    occurrences: tuple[SourceOccurrence, ...]
    dynamic_localizations: tuple[DynamicLocalizationOccurrence, ...]
    unknown_interpolations: tuple[UnknownInterpolationOccurrence, ...]
    english_strings: dict[str, str]
    spanish_strings: dict[str, str]
    english_plurals: dict[str, object]
    spanish_plurals: dict[str, object]
    issues: tuple[Issue, ...]

    @property
    def source_keys(self) -> set[str]:
        return {occurrence.key for occurrence in self.occurrences}


@dataclasses.dataclass(frozen=True)
class Token:
    kind: str
    text: str
    value: str
    line: int


def _skip_block_comment(text: str, index: int) -> int:
    depth = 1
    index += 2
    while index < len(text) and depth:
        if text.startswith("/*", index):
            depth += 1
            index += 2
        elif text.startswith("*/", index):
            depth -= 1
            index += 2
        else:
            index += 1
    return index


def _read_swift_string(text: str, index: int) -> tuple[int, str] | None:
    start = index
    hash_count = 0
    while index < len(text) and text[index] == "#":
        hash_count += 1
        index += 1
    if index >= len(text) or text[index] != '"':
        return None

    triple = text.startswith('"""', index)
    quote = '"""' if triple else '"'
    index += len(quote)
    content_start = index
    closing = quote + ("#" * hash_count)
    interpolation = "\\" + ("#" * hash_count) + "("

    while index < len(text):
        if text.startswith(interpolation, index):
            index += len(interpolation)
            depth = 1
            while index < len(text) and depth:
                nested = _read_swift_string(text, index)
                if nested is not None:
                    index = nested[0]
                    continue
                if text.startswith("//", index):
                    newline = text.find("\n", index + 2)
                    index = len(text) if newline < 0 else newline
                    continue
                if text.startswith("/*", index):
                    index = _skip_block_comment(text, index)
                    continue
                if text[index] == "(":
                    depth += 1
                elif text[index] == ")":
                    depth -= 1
                index += 1
            continue
        if text.startswith(closing, index):
            raw = text[content_start:index]
            end = index + len(closing)
            if triple:
                if raw.startswith("\n"):
                    raw = raw[1:]
                raw = raw.rstrip(" \t")
                if raw.endswith("\n"):
                    raw = raw[:-1]
                raw = textwrap.dedent(raw)
            return end, _decode_swift_escapes(raw, hash_count)
        if hash_count == 0 and text[index] == "\\":
            index += 2
        else:
            index += 1

    raise ValueError(f"unterminated Swift string literal at offset {start}")


def _decode_swift_escapes(value: str, hash_count: int) -> str:
    if hash_count:
        return value
    replacements = {
        "0": "\0",
        "n": "\n",
        "r": "\r",
        "t": "\t",
        '"': '"',
        "\\": "\\",
    }
    output: list[str] = []
    index = 0
    while index < len(value):
        if value[index] == "\\" and index + 1 < len(value):
            escaped = value[index + 1]
            if escaped == "u" and value.startswith("\\u{", index):
                close = value.find("}", index + 3)
                if close > index + 3:
                    scalar = value[index + 3 : close]
                    if re.fullmatch(r"[0-9A-Fa-f]{1,8}", scalar):
                        output.append(chr(int(scalar, 16)))
                        index = close + 1
                        continue
            if escaped in replacements:
                output.append(replacements[escaped])
                index += 2
                continue
        output.append(value[index])
        index += 1
    return "".join(output)


def swift_tokens(text: str) -> Iterator[Token]:
    index = 0
    line = 1
    while index < len(text):
        if text[index].isspace():
            line += text[index] == "\n"
            index += 1
            continue
        if text.startswith("//", index):
            newline = text.find("\n", index + 2)
            index = len(text) if newline < 0 else newline
            continue
        if text.startswith("/*", index):
            end = _skip_block_comment(text, index)
            line += text[index:end].count("\n")
            index = end
            continue

        string = _read_swift_string(text, index)
        if string is not None:
            end, value = string
            yield Token("string", text[index:end], value, line)
            line += text[index:end].count("\n")
            index = end
            continue

        identifier = re.match(r"[A-Za-z_][A-Za-z0-9_]*", text[index:])
        if identifier:
            value = identifier.group(0)
            yield Token("identifier", value, value, line)
            index += len(value)
            continue

        yield Token("punctuation", text[index], text[index], line)
        index += 1


def _matching_token(
    tokens: list[Token], start: int, opening: str, closing: str
) -> int | None:
    depth = 0
    for index in range(start, len(tokens)):
        if tokens[index].text == opening:
            depth += 1
        elif tokens[index].text == closing:
            depth -= 1
            if depth == 0:
                return index
    return None


def _split_parameters(
    tokens: list[Token], start: int, end: int
) -> list[tuple[int, int]]:
    ranges: list[tuple[int, int]] = []
    argument_start = start
    depths = {"(": 0, "[": 0, "{": 0, "<": 0}
    pairs = {")": "(",
        "]": "[",
        "}": "{",
        ">": "<",
    }
    for index in range(start, end):
        text = tokens[index].text
        if text in depths:
            depths[text] += 1
        elif text in pairs and depths[pairs[text]]:
            depths[pairs[text]] -= 1
        elif text == "," and not any(depths.values()):
            ranges.append((argument_start, index))
            argument_start = index + 1
    if argument_start < end:
        ranges.append((argument_start, end))
    return ranges


def _localized_helper_definitions(
    tokens: list[Token],
) -> tuple[LocalizedHelperDefinition, ...]:
    definitions: list[LocalizedHelperDefinition] = []
    index = 0
    while index < len(tokens):
        if tokens[index].text != "func":
            index += 1
            continue
        name_index = index + 1
        if (
            name_index >= len(tokens)
            or tokens[name_index].kind != "identifier"
        ):
            index += 1
            continue
        name = tokens[name_index].text
        open_index = name_index + 1
        while open_index < len(tokens) and tokens[open_index].text != "(":
            if tokens[open_index].text == "{":
                break
            open_index += 1
        if open_index >= len(tokens) or tokens[open_index].text != "(":
            index += 1
            continue
        close_index = _matching_token(tokens, open_index, "(", ")")
        if close_index is None:
            index += 1
            continue

        localized_parameters: list[LocalizedHelperParameter] = []
        for position, (start, end) in enumerate(
            _split_parameters(tokens, open_index + 1, close_index)
        ):
            colon = next(
                (
                    candidate
                    for candidate in range(start, end)
                    if tokens[candidate].text == ":"
                ),
                None,
            )
            if colon is None:
                continue
            equals = next(
                (
                    candidate
                    for candidate in range(colon + 1, end)
                    if tokens[candidate].text == "="
                ),
                end,
            )
            type_name = "".join(
                token.text for token in tokens[colon + 1 : equals]
            ).rstrip("?!")
            if type_name not in LOCALIZED_PARAMETER_TYPES:
                continue
            names = [
                token.text
                for token in tokens[start:colon]
                if token.kind == "identifier"
            ]
            if not names:
                continue
            if names[0] == "_":
                external_label = None
                internal_name = names[1] if len(names) > 1 else "_"
            else:
                external_label = names[0]
                internal_name = names[-1]
            localized_parameters.append(
                LocalizedHelperParameter(
                    position, external_label, internal_name
                )
            )

        body_start: int | None = None
        body_end: int | None = None
        cursor = close_index + 1
        while cursor < len(tokens):
            if tokens[cursor].text == "{":
                body_start = cursor
                body_end = _matching_token(tokens, cursor, "{", "}")
                break
            if tokens[cursor].text == "func":
                break
            cursor += 1
        if localized_parameters:
            definitions.append(
                LocalizedHelperDefinition(
                    name,
                    tuple(localized_parameters),
                    body_start,
                    body_end,
                )
            )
        index = close_index + 1
    return tuple(definitions)


def _global_localized_helpers(
    paths: Iterable[pathlib.Path],
) -> dict[str, tuple[LocalizedHelperParameter, ...]]:
    grouped: dict[str, set[LocalizedHelperParameter]] = (
        collections.defaultdict(set)
    )
    for path in paths:
        definitions = _localized_helper_definitions(
            list(swift_tokens(path.read_text(encoding="utf-8")))
        )
        for definition in definitions:
            grouped[definition.name].update(definition.parameters)
    return {
        name: tuple(
            sorted(
                parameters,
                key=lambda parameter: (
                    parameter.position,
                    parameter.external_label or "",
                    parameter.internal_name,
                ),
            )
        )
        for name, parameters in grouped.items()
    }


def _call_argument_context(
    tokens: list[Token], literal_index: int
) -> tuple[str, int, str | None] | None:
    depths = {"(": 0, "[": 0, "{": 0}
    closing = {")": "(",
        "]": "[",
        "}": "{",
    }
    argument_position = 0
    argument_start = literal_index
    open_index: int | None = None
    for index in range(literal_index - 1, -1, -1):
        text = tokens[index].text
        if text in closing:
            depths[closing[text]] += 1
        elif text in depths:
            if depths[text]:
                depths[text] -= 1
            elif text == "(":
                open_index = index
                break
            else:
                return None
        elif text == "," and not any(depths.values()):
            if argument_position == 0:
                argument_start = index + 1
            argument_position += 1
    if open_index is None or open_index == 0:
        return None
    if argument_position == 0:
        argument_start = open_index + 1
    name_token = tokens[open_index - 1]
    if name_token.kind != "identifier":
        return None
    direct = tokens[argument_start : literal_index + 1]
    if len(direct) == 1:
        label = None
    elif (
        len(direct) == 3
        and direct[0].kind == "identifier"
        and direct[1].text == ":"
    ):
        label = direct[0].text
    else:
        return None
    return name_token.text, argument_position, label


def _swift_type_environment(source: str) -> SwiftTypeEnvironment:
    candidates: dict[str, set[str]] = collections.defaultdict(set)
    type_name = r"[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)?"
    for match in re.finditer(
        rf"\b([A-Za-z_][A-Za-z0-9_]*)\s*:\s*({type_name})\??\b",
        source,
    ):
        candidates[match.group(1)].add(match.group(2))
    for match in re.finditer(
        r"\b(?:let|var)\s+([A-Za-z_][A-Za-z0-9_]*)\s*=\s*"
        r"(?:(-?\d+\.\d+)|(-?\d+\b)|(?:\"[^\"]*\")|(true|false))",
        source,
    ):
        if match.group(2) is not None:
            candidates[match.group(1)].add("Double")
        elif match.group(3) is not None:
            candidates[match.group(1)].add("Int")
        elif match.group(4) is not None:
            candidates[match.group(1)].add("Bool")
        else:
            candidates[match.group(1)].add("String")
    for match in re.finditer(
        r"\b(?:let|var)\s+([A-Za-z_][A-Za-z0-9_]*)\s*=\s*[^\n]*\.count\b",
        source,
    ):
        candidates[match.group(1)].add("Int")
    variables = {
        name: next(iter(types))
        for name, types in candidates.items()
        if len(types) == 1
    }
    members: dict[tuple[str, str], str] = {}
    tokens = list(swift_tokens(source))
    for index, token in enumerate(tokens[:-2]):
        if token.text not in {"struct", "class", "actor"}:
            continue
        nominal = tokens[index + 1]
        if nominal.kind != "identifier":
            continue
        open_index = index + 2
        while open_index < len(tokens) and tokens[open_index].text != "{":
            open_index += 1
        if open_index >= len(tokens):
            continue
        close_index = _matching_token(tokens, open_index, "{", "}")
        if close_index is None:
            continue
        depth = 1
        cursor = open_index + 1
        while cursor < close_index:
            text = tokens[cursor].text
            if text == "{":
                depth += 1
            elif text == "}":
                depth -= 1
            elif (
                depth == 1
                and text in {"let", "var"}
                and cursor + 2 < close_index
                and tokens[cursor + 1].kind == "identifier"
                and tokens[cursor + 2].text == ":"
            ):
                member_name = tokens[cursor + 1].text
                type_cursor = cursor + 3
                declared_type = ""
                if (
                    type_cursor < close_index
                    and tokens[type_cursor].kind == "identifier"
                ):
                    declared_type = tokens[type_cursor].text
                    if (
                        type_cursor + 2 < close_index
                        and tokens[type_cursor + 1].text == "."
                        and tokens[type_cursor + 2].kind
                        == "identifier"
                    ):
                        declared_type += (
                            "." + tokens[type_cursor + 2].text
                        )
                if re.fullmatch(type_name, declared_type):
                    members[(nominal.text, member_name)] = declared_type
            cursor += 1
    return SwiftTypeEnvironment(variables, members)


def _global_swift_type_members(
    paths: Iterable[pathlib.Path],
) -> dict[tuple[str, str], str]:
    candidates: dict[tuple[str, str], set[str]] = collections.defaultdict(set)
    for path in paths:
        environment = _swift_type_environment(
            path.read_text(encoding="utf-8")
        )
        for member, value_type in environment.members.items():
            candidates[member].add(value_type)
    return {
        member: next(iter(value_types))
        for member, value_types in candidates.items()
        if len(value_types) == 1
    }


def _placeholder_for_swift_type(value_type: str) -> str:
    if value_type == "Int":
        return "%lld"
    if value_type == "UInt":
        return "%llu"
    if value_type in {"Int8", "Int16", "Int32", "pid_t", "OSStatus"}:
        return "%d"
    if value_type == "Int64":
        return "%lld"
    if value_type in {"UInt8", "UInt16", "UInt32"}:
        return "%u"
    if value_type == "UInt64":
        return "%llu"
    if value_type == "Float":
        return "%f"
    if value_type == "Double":
        return "%lf"
    if value_type in {
        "String",
        "Substring",
        "Character",
        "Bool",
        "Date",
        "URL",
        "UUID",
    }:
        return "%@"
    raise ValueError(f"unsupported Swift interpolation type: {value_type}")


def _swift_interpolation_placeholder(
    expression: str, type_environment: SwiftTypeEnvironment
) -> str | None:
    specifier = re.search(r'\bspecifier\s*:\s*"([^"]+)"', expression)
    if specifier:
        candidate = specifier.group(1)
        if PRINTF_PLACEHOLDER.fullmatch(candidate):
            return candidate
        return None
    expression = expression.strip()
    if re.fullmatch(r"-?\d+", expression):
        return "%lld"
    if re.fullmatch(r"-?\d+\.\d+", expression):
        return "%lf"
    if expression.startswith('"') and expression.endswith('"'):
        return "%@"
    if re.search(r"\bformat\s*:", expression):
        return "%@"
    if re.search(r'\?\?\s*"', expression):
        return "%@"
    if re.search(r"\?\?\s*String\s*\(\s*localized\s*:", expression):
        return "%@"
    if re.search(r'\?\s*"[^"\n]*"\s*:\s*"', expression):
        return "%@"
    if re.search(
        r"(?:\.formatted\s*\(|\.localizedDescription\b|"
        r"\.uuidString(?:\.lowercased\s*\(\))?|\.url\.path\b|"
        r"\.lastPathComponent\b)",
        expression,
    ):
        return "%@"
    if re.match(
        r"(?:LocalizedCount\.|ByteCountFormatter\.string\(|"
        r"Self\.editFieldList\(|label\(for:|description\(for:|"
        r"ProfileEditorSecurityPresentation\.locationDescription\()",
        expression,
    ):
        return "%@"
    identifier = re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", expression)
    if identifier and identifier.group(0) in type_environment.variables:
        try:
            return _placeholder_for_swift_type(
                type_environment.variables[identifier.group(0)]
            )
        except ValueError:
            pass
    member = re.fullmatch(
        r"[A-Za-z_][A-Za-z0-9_]*"
        r"(?:\.[A-Za-z_][A-Za-z0-9_]*)+",
        expression,
    )
    if member:
        parts = expression.split(".")
        inferred = type_environment.variables.get(parts[0])
        for part in parts[1:]:
            if inferred == "UUID" and part == "uuidString":
                inferred = "String"
            elif inferred is not None:
                inferred = type_environment.members.get((inferred, part))
            if inferred is None:
                break
        if inferred is not None:
            try:
                return _placeholder_for_swift_type(inferred)
            except ValueError:
                pass
        final_member = parts[-1]
        member_types = {
            value_type
            for (nominal, name), value_type in type_environment.members.items()
            if name == final_member
        }
        if len(member_types) == 1:
            try:
                return _placeholder_for_swift_type(next(iter(member_types)))
            except ValueError:
                pass
        if final_member == "count":
            return "%lld"
    terminal = re.search(r"([A-Za-z_][A-Za-z0-9_]*)$", expression)
    if terminal:
        name = terminal.group(1)
        if re.search(
            r"(?:Count|count|processIdentifier|Attempts?|attempt|Column|"
            r"found|supported|version|usagePercent)$",
            name,
        ):
            return "%lld"
        if re.search(
            r"(?:Name|name|Path|path|Label|label|Detail|detail|"
            r"Message|message|Status|status|duration|relative|conflictNames|"
            r"configurations|profiles|bundleIdentifier|Prefix|copyError|"
            r"persistenceError)$",
            name,
        ):
            return "%@"
    if expression == "operation.rawValue":
        return "%@"
    return None


def _normalized_swift_localization_key(
    value: str, type_environment: SwiftTypeEnvironment
) -> NormalizedLocalizationKey:
    output: list[str] = []
    unknown: list[str] = []
    index = 0
    interpolation = re.compile(r"\\(?:#+)?\(")
    while index < len(value):
        match = interpolation.search(value, index)
        if match is None:
            output.append(value[index:])
            break
        output.append(value[index : match.start()])
        cursor = match.end()
        expression_start = cursor
        depth = 1
        quote: str | None = None
        escaped = False
        while cursor < len(value) and depth:
            character = value[cursor]
            if quote is not None:
                if escaped:
                    escaped = False
                elif character == "\\":
                    escaped = True
                elif character == quote:
                    quote = None
            elif character in {'"', "'"}:
                quote = character
            elif character == "(":
                depth += 1
            elif character == ")":
                depth -= 1
            cursor += 1
        if depth:
            expression = value[expression_start:]
            unknown.append(expression)
            output.append(value[match.start() :])
            break
        expression = value[expression_start : cursor - 1]
        placeholder = _swift_interpolation_placeholder(
            expression, type_environment
        )
        if placeholder is None:
            unknown.append(expression.strip())
            output.append("<unknown>")
        else:
            output.append(placeholder)
        index = cursor
    return NormalizedLocalizationKey("".join(output), tuple(unknown))


def normalize_swift_localization_key(
    value: str, type_environment: SwiftTypeEnvironment
) -> str:
    return _normalized_swift_localization_key(
        value, type_environment
    ).key


def extract_swift_occurrences(
    path: pathlib.Path,
    display_path: str,
    global_localized_helpers: dict[
        str, tuple[LocalizedHelperParameter, ...]
    ] | None = None,
    global_type_members: dict[tuple[str, str], str] | None = None,
) -> tuple[list[SourceOccurrence], list[UnknownInterpolationOccurrence]]:
    source = path.read_text(encoding="utf-8")
    helpers = global_localized_helpers or {}
    local_type_environment = _swift_type_environment(source)
    type_environment = SwiftTypeEnvironment(
        local_type_environment.variables,
        {
            **(global_type_members or {}),
            **local_type_environment.members,
        },
    )
    tokens = list(swift_tokens(source))
    occurrences: list[SourceOccurrence] = []
    unknown_interpolations: list[UnknownInterpolationOccurrence] = []
    unknown_ordinals: collections.Counter[str] = collections.Counter()
    for index, token in enumerate(tokens):
        if token.kind != "string" or not token.value:
            continue

        surface: str | None = None
        if (
            index >= 4
            and tokens[index - 1].text == ":"
            and tokens[index - 2].text == "localized"
            and tokens[index - 3].text == "("
            and tokens[index - 4].text == "String"
        ):
            surface = "String(localized:)"
        elif (
            index >= 2
            and tokens[index - 1].text == "("
            and tokens[index - 2].kind == "identifier"
            and tokens[index - 2].text in SWIFTUI_LOCALIZED_CALLS
        ):
            surface = tokens[index - 2].text
        elif (
            index >= 3
            and tokens[index - 1].text == "="
            and tokens[index - 2].text == "LocalizedStringKey"
            and tokens[index - 3].text == ":"
        ):
            surface = "LocalizedStringKey assignment"
        else:
            context = _call_argument_context(tokens, index)
            if context is not None:
                helper_name, position, label = context
                if any(
                    (
                        label is not None
                        and parameter.external_label == label
                    )
                    or (
                        label is None
                        and parameter.external_label is None
                        and parameter.position == position
                    )
                    for parameter in helpers.get(helper_name, ())
                ):
                    surface = helper_name

        if surface is not None:
            normalized = _normalized_swift_localization_key(
                token.value, type_environment
            )
            if normalized.unknown_expressions:
                for expression in normalized.unknown_expressions:
                    unknown_ordinals[expression] += 1
                    unknown_interpolations.append(
                        UnknownInterpolationOccurrence(
                            display_path,
                            token.line,
                            expression,
                            unknown_ordinals[expression],
                        )
                    )
                continue
            occurrences.append(
                SourceOccurrence(
                    normalized.key,
                    display_path,
                    token.line,
                    surface,
                )
            )
    return occurrences, unknown_interpolations


def _source_inventory(
    source_root: pathlib.Path,
) -> tuple[
    tuple[SourceOccurrence, ...],
    tuple[UnknownInterpolationOccurrence, ...],
]:
    occurrences: list[SourceOccurrence] = []
    unknown_interpolations: list[UnknownInterpolationOccurrence] = []
    paths = sorted(source_root.rglob("*.swift"))
    helpers = _global_localized_helpers(paths)
    type_members = _global_swift_type_members(paths)
    for path in paths:
        display = path.relative_to(source_root).as_posix()
        extracted, unknown = extract_swift_occurrences(
            path, display, helpers, type_members
        )
        occurrences.extend(extracted)
        unknown_interpolations.extend(unknown)
    return tuple(occurrences), tuple(unknown_interpolations)


def source_inventory(source_root: pathlib.Path) -> tuple[SourceOccurrence, ...]:
    return _source_inventory(source_root)[0]


def unknown_interpolation_inventory(
    source_root: pathlib.Path,
) -> tuple[UnknownInterpolationOccurrence, ...]:
    return _source_inventory(source_root)[1]


def _localized_parameter_scopes(
    tokens: list[Token],
) -> tuple[tuple[int, int, frozenset[str]], ...]:
    scopes: list[tuple[int, int, frozenset[str]]] = []
    for definition in _localized_helper_definitions(tokens):
        if definition.body_start is None or definition.body_end is None:
            continue
        scopes.append(
            (
                definition.body_start,
                definition.body_end,
                frozenset(
                    parameter.internal_name
                    for parameter in definition.parameters
                ),
            )
        )
    return tuple(scopes)


def _is_localized_parameter_passthrough(
    tokens: list[Token], expression_index: int, scopes: tuple[
        tuple[int, int, frozenset[str]], ...
    ]
) -> bool:
    expression = tokens[expression_index]
    if expression.kind != "identifier":
        return False
    if expression_index + 1 >= len(tokens) or tokens[
        expression_index + 1
    ].text not in {",", ")"}:
        return False
    return any(
        start < expression_index < end and expression.text in names
        for start, end, names in scopes
    )


def dynamic_localization_inventory(
    source_root: pathlib.Path,
) -> tuple[DynamicLocalizationOccurrence, ...]:
    occurrences: list[DynamicLocalizationOccurrence] = []
    ordinals: collections.Counter[tuple[str, str]] = collections.Counter()
    for path in sorted(source_root.rglob("*.swift")):
        tokens = list(swift_tokens(path.read_text(encoding="utf-8")))
        scopes = _localized_parameter_scopes(tokens)
        display = path.relative_to(source_root).as_posix()
        for index in range(len(tokens) - 4):
            if (
                tokens[index].text == "String"
                and tokens[index + 1].text == "("
                and tokens[index + 2].text == "localized"
                and tokens[index + 3].text == ":"
                and tokens[index + 4].kind != "string"
            ):
                if _is_localized_parameter_passthrough(
                    tokens, index + 4, scopes
                ):
                    continue
                expression = tokens[index + 4].text
                ordinals[(display, expression)] += 1
                occurrences.append(
                    DynamicLocalizationOccurrence(
                        display,
                        tokens[index].line,
                        expression,
                        ordinals[(display, expression)],
                    )
                )
    return tuple(occurrences)


def _read_quoted_catalog_string(text: str, index: int) -> tuple[int, str]:
    if text[index] != '"':
        raise ValueError("expected quoted catalog string")
    index += 1
    value: list[str] = []
    escapes = {'"': '"', "\\": "\\", "n": "\n", "r": "\r", "t": "\t"}
    while index < len(text):
        character = text[index]
        if character == '"':
            return index + 1, "".join(value)
        if character == "\\" and index + 1 < len(text):
            escaped = text[index + 1]
            if escaped in {"u", "U"}:
                digits = text[index + 2 : index + 6]
                if len(digits) == 4 and re.fullmatch(r"[0-9A-Fa-f]{4}", digits):
                    value.append(chr(int(digits, 16)))
                    index += 6
                    continue
            if escaped in escapes:
                value.append(escapes[escaped])
            else:
                value.extend(("\\", escaped))
            index += 2
        else:
            value.append(character)
            index += 1
    raise ValueError("unterminated quoted catalog string")


def parse_strings_catalog(path: pathlib.Path) -> tuple[dict[str, str], list[str]]:
    text = path.read_text(encoding="utf-8")
    index = 0
    result: dict[str, str] = {}
    duplicates: list[str] = []

    def skip_trivia(position: int) -> int:
        while position < len(text):
            if text[position].isspace():
                position += 1
            elif text.startswith("//", position):
                newline = text.find("\n", position + 2)
                position = len(text) if newline < 0 else newline
            elif text.startswith("/*", position):
                position = _skip_block_comment(text, position)
            else:
                break
        return position

    while True:
        index = skip_trivia(index)
        if index >= len(text):
            break
        index, key = _read_quoted_catalog_string(text, index)
        index = skip_trivia(index)
        if index >= len(text) or text[index] != "=":
            raise ValueError(f"expected '=' after key {key!r} in {path}")
        index = skip_trivia(index + 1)
        index, value = _read_quoted_catalog_string(text, index)
        index = skip_trivia(index)
        if index >= len(text) or text[index] != ";":
            raise ValueError(f"expected ';' after key {key!r} in {path}")
        index += 1
        if key in result:
            duplicates.append(key)
        result[key] = value
    return result, duplicates


def parse_stringsdict(path: pathlib.Path) -> dict[str, object]:
    with path.open("rb") as handle:
        value = plistlib.load(handle)
    if not isinstance(value, dict):
        raise ValueError(f"{path} must contain a dictionary")
    return value


def format_placeholders(value: str) -> tuple[FormatPlaceholder, ...]:
    scrubbed = value.replace("%%", "")
    return tuple(
        FormatPlaceholder(
            int(match.group("position")) if match.group("position") else None,
            _canonical_format_type(match.group("type")),
        )
        for match in PRINTF_PLACEHOLDER.finditer(scrubbed)
    )


def _canonical_format_type(value_type: str) -> str:
    if value_type in {"i", "d"}:
        return "d"
    if value_type in {"li", "ld"}:
        return "ld"
    if value_type in {"lli", "lld", "qd"}:
        return "lld"
    if value_type == "lf":
        return "f"
    return value_type


def _argument_types(
    placeholders: tuple[FormatPlaceholder, ...]
) -> tuple[dict[int, str] | None, str | None]:
    positioned = [item.position is not None for item in placeholders]
    if any(positioned) and not all(positioned):
        return None, "mixes positioned and unpositioned placeholders"

    arguments: dict[int, str] = {}
    for index, placeholder in enumerate(placeholders, start=1):
        position = placeholder.position or index
        if position <= 0:
            return None, "uses a nonpositive argument position"
        if position in arguments:
            return None, f"uses argument {position} more than once"
        arguments[position] = placeholder.value_type
    if arguments and set(arguments) != set(range(1, len(arguments) + 1)):
        return None, "uses noncontiguous argument positions"
    return arguments, None


def format_compatibility(format_key: str, localized_value: str) -> str | None:
    expected, expected_error = _argument_types(format_placeholders(format_key))
    actual, actual_error = _argument_types(format_placeholders(localized_value))
    if expected_error:
        return f"format-bearing key {expected_error}"
    if actual_error:
        return f"localized value {actual_error}"
    if expected != actual:
        return f"expected arguments {expected or {}}, found {actual or {}}"
    return None


def _intrinsic_plural_issues(
    locale: str, plurals: dict[str, object]
) -> Iterable[Issue]:
    for key, entry in sorted(plurals.items()):
        if not isinstance(entry, dict):
            yield Issue(
                f"plural-invalid-entry-{locale}",
                key,
                "plural entry must be a dictionary",
            )
            continue
        outer_format = entry.get("NSStringLocalizedFormatKey")
        if not isinstance(outer_format, str) or not outer_format:
            yield Issue(
                f"plural-invalid-outer-format-{locale}",
                key,
                "NSStringLocalizedFormatKey must be a nonempty string",
            )
            continue
        referenced = PLURAL_REFERENCE.findall(outer_format)
        if not referenced:
            yield Issue(
                f"plural-missing-reference-{locale}",
                key,
                "outer plural format must reference at least one rule variable",
            )
        if len(referenced) != len(set(referenced)):
            yield Issue(
                f"plural-duplicate-reference-{locale}",
                key,
                "outer plural format references a rule variable more than once",
            )
        defined = {
            name
            for name, value in entry.items()
            if name != "NSStringLocalizedFormatKey" and isinstance(value, dict)
        }
        for variable in sorted(set(referenced) - defined):
            yield Issue(
                f"plural-missing-variable-{locale}",
                f"{key}/{variable}",
                "referenced plural rule variable is missing",
            )
        for variable in sorted(defined - set(referenced)):
            yield Issue(
                f"plural-unreferenced-variable-{locale}",
                f"{key}/{variable}",
                "plural rule variable is not referenced by the outer format",
            )
        for variable in sorted(defined):
            rule = entry[variable]
            assert isinstance(rule, dict)
            if rule.get("NSStringFormatSpecTypeKey") != "NSStringPluralRuleType":
                yield Issue(
                    f"plural-invalid-spec-type-{locale}",
                    f"{key}/{variable}",
                    "NSStringFormatSpecTypeKey must be NSStringPluralRuleType",
                )
            value_type = rule.get("NSStringFormatValueTypeKey")
            if not isinstance(value_type, str) or not value_type:
                yield Issue(
                    f"plural-missing-value-type-{locale}",
                    f"{key}/{variable}",
                    "NSStringFormatValueTypeKey must be a nonempty string",
                )
                value_type = None
            elif PLURAL_VALUE_TYPE.fullmatch(value_type) is None:
                yield Issue(
                    f"plural-invalid-value-type-{locale}",
                    f"{key}/{variable}",
                    (
                        "NSStringFormatValueTypeKey must be a valid "
                        "numeric printf scalar type"
                    ),
                )
                value_type = None
            categories = set(rule) - PLURAL_METADATA_KEYS
            if not {"one", "other"}.issubset(categories):
                yield Issue(
                    f"plural-missing-required-category-{locale}",
                    f"{key}/{variable}",
                    "English and Spanish plural rules require one and other",
                )
            for category in sorted(categories):
                category_value = rule[category]
                if not isinstance(category_value, str):
                    yield Issue(
                        f"plural-nonstring-category-{locale}",
                        f"{key}/{variable}/{category}",
                        "plural category value must be a string",
                    )
                    continue
                if value_type is None:
                    yield Issue(
                        f"plural-placeholder-incompatible-{locale}",
                        f"{key}/{variable}/{category}",
                        (
                            "plural category placeholder compatibility "
                            "cannot be established without a valid value type"
                        ),
                    )
                else:
                    incompatibility = format_compatibility(
                        "%" + value_type, category_value
                    )
                    if incompatibility:
                        yield Issue(
                            f"plural-placeholder-incompatible-{locale}",
                            f"{key}/{variable}/{category}",
                            incompatibility,
                        )


def _plural_issues(
    english: dict[str, object], spanish: dict[str, object]
) -> Iterable[Issue]:
    yield from _intrinsic_plural_issues("en", english)
    yield from _intrinsic_plural_issues("es", spanish)
    for key in sorted(set(english) | set(spanish)):
        if key not in english or key not in spanish:
            missing = "en" if key not in english else "es"
            yield Issue(
                f"plural-missing-{missing}", key, f"plural key is missing from {missing}"
            )
            continue
        en_entry = english[key]
        es_entry = spanish[key]
        if not isinstance(en_entry, dict) or not isinstance(es_entry, dict):
            continue
        en_format = en_entry.get("NSStringLocalizedFormatKey")
        es_format = es_entry.get("NSStringLocalizedFormatKey")
        if isinstance(en_format, str) and isinstance(es_format, str):
            if collections.Counter(PLURAL_REFERENCE.findall(en_format)) != collections.Counter(
                PLURAL_REFERENCE.findall(es_format)
            ):
                yield Issue(
                    "plural-format-reference-mismatch",
                    key,
                    "plural variable references differ between en and es",
                )
            incompatibility = format_compatibility(en_format, es_format)
            if incompatibility:
                yield Issue("plural-outer-placeholder-mismatch", key, incompatibility)
        variables = {
            name
            for name in set(en_entry) | set(es_entry)
            if name != "NSStringLocalizedFormatKey"
        }
        for variable in sorted(variables):
            en_rule = en_entry.get(variable)
            es_rule = es_entry.get(variable)
            if not isinstance(en_rule, dict) or not isinstance(es_rule, dict):
                yield Issue(
                    "plural-variable-mismatch",
                    f"{key}/{variable}",
                    "plural variable is not defined as a rule in both locales",
                )
                continue
            en_categories = set(en_rule) - PLURAL_METADATA_KEYS
            es_categories = set(es_rule) - PLURAL_METADATA_KEYS
            if en_categories != es_categories:
                yield Issue(
                    "plural-category-mismatch",
                    f"{key}/{variable}",
                    f"en categories {sorted(en_categories)}; es categories {sorted(es_categories)}",
                )
            if en_rule.get("NSStringFormatValueTypeKey") != es_rule.get(
                "NSStringFormatValueTypeKey"
            ):
                yield Issue(
                    "plural-value-type-mismatch",
                    f"{key}/{variable}",
                    "plural value types differ between en and es",
                )


def audit_project(source_root: pathlib.Path, resources_root: pathlib.Path) -> AuditResult:
    occurrences, unknown_interpolations = _source_inventory(source_root)
    dynamic_localizations = dynamic_localization_inventory(source_root)
    en_strings, en_duplicates = parse_strings_catalog(
        resources_root / "en.lproj" / "Localizable.strings"
    )
    es_strings, es_duplicates = parse_strings_catalog(
        resources_root / "es.lproj" / "Localizable.strings"
    )
    en_plurals = parse_stringsdict(
        resources_root / "en.lproj" / "Localizable.stringsdict"
    )
    es_plurals = parse_stringsdict(
        resources_root / "es.lproj" / "Localizable.stringsdict"
    )
    issues: list[Issue] = []

    for occurrence in dynamic_localizations:
        issues.append(
            Issue(
                "dynamic-localization-key",
                (
                    f"{occurrence.path}:{occurrence.expression}"
                    f"#{occurrence.ordinal}"
                ),
                f"String(localized:) uses a nonliteral key at line {occurrence.line}",
            )
        )

    for occurrence in unknown_interpolations:
        issues.append(
            Issue(
                "unknown-localization-interpolation",
                (
                    f"{occurrence.path}:{occurrence.expression}"
                    f"#{occurrence.ordinal}"
                ),
                (
                    "localized interpolation has no safely inferred "
                    f"placeholder type at line {occurrence.line}"
                ),
            )
        )

    for locale, duplicates in (("en", en_duplicates), ("es", es_duplicates)):
        for key in sorted(set(duplicates)):
            issues.append(
                Issue(f"duplicate-catalog-key-{locale}", key, "duplicate .strings key")
            )

    all_en = set(en_strings) | set(en_plurals)
    all_es = set(es_strings) | set(es_plurals)
    for locale, strings, plurals in (
        ("en", en_strings, en_plurals),
        ("es", es_strings, es_plurals),
    ):
        for key in sorted(set(strings) & set(plurals)):
            issues.append(
                Issue(
                    f"catalog-key-kind-collision-{locale}",
                    key,
                    "key exists in both .strings and .stringsdict",
                )
            )
    for key in sorted({occurrence.key for occurrence in occurrences}):
        missing_en = key not in all_en
        missing_es = key not in all_es
        if missing_en and missing_es:
            issues.append(
                Issue(
                    "source-key-missing-both",
                    key,
                    "localized source literal is absent from both packaged catalogs",
                )
            )
        elif missing_en:
            issues.append(Issue("source-key-missing-en", key, "source key is absent from en"))
        elif missing_es:
            issues.append(Issue("source-key-missing-es", key, "source key is absent from es"))

    for key in sorted(set(en_strings) | set(es_strings)):
        if key not in en_strings:
            issues.append(Issue("catalog-key-missing-en", key, "key exists only in es"))
        elif key not in es_strings:
            issues.append(Issue("catalog-key-missing-es", key, "key exists only in en"))
        else:
            for locale, localized_value in (
                ("en", en_strings[key]),
                ("es", es_strings[key]),
            ):
                incompatibility = format_compatibility(key, localized_value)
                if incompatibility:
                    issues.append(
                        Issue(
                            f"placeholder-key-mismatch-{locale}",
                            key,
                            incompatibility,
                        )
                    )

    issues.extend(_plural_issues(en_plurals, es_plurals))
    issues.sort(key=lambda issue: (issue.code, issue.key))
    return AuditResult(
        occurrences,
        dynamic_localizations,
        unknown_interpolations,
        en_strings,
        es_strings,
        en_plurals,
        es_plurals,
        tuple(issues),
    )


def load_baseline(path: pathlib.Path) -> set[str]:
    value = json.loads(path.read_text(encoding="utf-8"))
    if (
        value.get("schema_version") != 1
        or not isinstance(value.get("purpose"), str)
        or not value["purpose"].strip()
        or not isinstance(value.get("allowed_issues"), list)
        or not all(isinstance(item, str) for item in value["allowed_issues"])
    ):
        raise ValueError(f"invalid localization baseline: {path}")
    return set(value["allowed_issues"])


def write_baseline(path: pathlib.Path, result: AuditResult) -> None:
    value = {
        "schema_version": 1,
        "purpose": (
            "Known localization census debt only. This allowlist is not evidence "
            "that English or Spanish translation is complete or reviewed."
        ),
        "allowed_issues": sorted(issue.fingerprint for issue in result.issues),
    }
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def _repository_root() -> pathlib.Path:
    return pathlib.Path(__file__).resolve().parent.parent


def main(argv: list[str] | None = None) -> int:
    root = _repository_root()
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-root", type=pathlib.Path, default=root / "Sources" / "Parallax")
    parser.add_argument(
        "--resources-root",
        type=pathlib.Path,
        default=root / "Sources" / "Parallax" / "Resources",
    )
    parser.add_argument(
        "--baseline",
        type=pathlib.Path,
        default=root / "script" / "localization_completeness_baseline.json",
    )
    parser.add_argument("--write-baseline", type=pathlib.Path)
    parser.add_argument("--json-report", type=pathlib.Path)
    args = parser.parse_args(argv)

    try:
        result = audit_project(args.source_root, args.resources_root)
        if args.write_baseline:
            write_baseline(args.write_baseline, result)
            print(f"wrote {len(result.issues)} known issues to {args.write_baseline}")
            return 0

        allowed = load_baseline(args.baseline)
    except (OSError, ValueError, plistlib.InvalidFileException, json.JSONDecodeError) as error:
        print(f"localization census configuration error: {error}", file=sys.stderr)
        return 2

    current = {issue.fingerprint for issue in result.issues}
    new = [issue for issue in result.issues if issue.fingerprint not in allowed]
    stale = sorted(allowed - current)
    print(
        "localization census: "
        f"{len(result.source_keys)} source keys from {len(result.occurrences)} literals; "
        f"dynamic keys={len(result.dynamic_localizations)}; "
        f"unknown interpolations={len(result.unknown_interpolations)}; "
        f"en={len(result.english_strings) + len(result.english_plurals)}, "
        f"es={len(result.spanish_strings) + len(result.spanish_plurals)}; "
        f"known debt={len(current) - len(new)}, new issues={len(new)}, "
        f"resolved baseline entries={len(stale)}"
    )
    if stale:
        print("stale baseline entries must be removed:", file=sys.stderr)
        for fingerprint in stale:
            print(f"  - {fingerprint}", file=sys.stderr)
    if new:
        print("new localization census issues:", file=sys.stderr)
        for issue in new:
            print(f"  - {issue.fingerprint}: {issue.detail}", file=sys.stderr)

    if args.json_report:
        report = {
            "source_key_count": len(result.source_keys),
            "source_literal_count": len(result.occurrences),
            "dynamic_localization_count": len(result.dynamic_localizations),
            "unknown_interpolation_count": len(result.unknown_interpolations),
            "english_catalog_key_count": len(result.english_strings) + len(result.english_plurals),
            "spanish_catalog_key_count": len(result.spanish_strings) + len(result.spanish_plurals),
            "new_issues": [dataclasses.asdict(issue) for issue in new],
            "known_issue_count": len(current) - len(new),
            "resolved_baseline_entries": stale,
        }
        args.json_report.write_text(
            json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
        )
    return 1 if new or stale else 0


if __name__ == "__main__":
    raise SystemExit(main())
