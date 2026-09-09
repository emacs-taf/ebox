#!/usr/bin/env python3
"""Migrate explicit Elisp paths to Ebox CSS sizes without evaluating their code.

Dry-run: python3 scripts/migrate-css-sizes.py ../ebox-playground/examples
Apply:   python3 scripts/migrate-css-sizes.py --write path/to/example.ebox
Scoped:  python3 scripts/migrate-css-sizes.py --callers ebox-build,ebox-create tests
Tests:   python3 -m unittest discover -s scripts -p 'test_migrate_css_sizes.py'

Directories include .el/.ebox/.etaf/.ecss files and skip generated, Git, and historical
trees. Comments, strings, reader quoting, and whitespace outside replaced
values are preserved. This is a property migration, not a type checker: pass
public style/DSL callers, not engine structs whose similarly named fields are
already measured sizes. Inspect the diff. Dynamic expressions, removed forms,
and ambiguous axes are reported for manual review, never evaluated or guessed.
Inline units are px/ch/vw/%, block units are lh/vh/%, and border strokes use
non-percent lengths. Function operands obey the same rule recursively. Flex
bases use a directly enclosing Flex direction when statically available.
Exit 0 means no review items, 1 means review is needed, 2 means an I/O or reader
error. --write applies safe edits even when review items remain. Each file is
atomically replaced; interruption/error cleans up its temporary file.
"""

import argparse
from dataclasses import dataclass, field
import os
from pathlib import Path
import re
import sys
import tempfile


NUMBER = re.compile(r"[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?\Z")
UNITS = {"px", "%", "vw", "vh", "ch", "lh"}
AXIS_UNITS = {"ch": {"px", "ch", "vw", "%"},
              "lh": {"lh", "vh", "%"},
              "px": UNITS - {"%"}, None: {"%"}}
FUNCTIONS = {"calc", "min", "max", "clamp"}
KEYWORDS = {"auto", "none", "min-content", "max-content", "fit-content"}
KEYWORDS.add("stretch")
SKIP_DIRS = {".git", ".omx", "node_modules", "target", "__pycache__",
             "emacs-box", "archive", "historical"}


@dataclass
class Form:
    start: int
    end: int
    kind: str
    text: str = ""
    children: list = field(default_factory=list)


class Reader:
    """A non-evaluating reader retaining source offsets, comments, and quoting."""

    def __init__(self, source):
        self.source = source
        self.pos = 0

    def whitespace(self):
        while self.pos < len(self.source):
            char = self.source[self.pos]
            if char.isspace():
                self.pos += 1
            elif char == ";":
                end = self.source.find("\n", self.pos)
                self.pos = len(self.source) if end < 0 else end + 1
            else:
                break

    def read(self):
        self.whitespace()
        start = self.pos
        if start == len(self.source):
            raise ValueError("unexpected end of input")
        char = self.source[self.pos]
        self.pos += 1
        if char in "([":
            closer = ")" if char == "(" else "]"
            children = []
            while True:
                self.whitespace()
                if self.pos == len(self.source):
                    raise ValueError(f"unclosed {char} at offset {start}")
                if self.source[self.pos] == closer:
                    self.pos += 1
                    return Form(start, self.pos, "list", char, children)
                children.append(self.read())
        if char in ")]":
            raise ValueError(f"unexpected {char} at offset {start}")
        if char in "'`," or (char == "#" and self.source[self.pos:self.pos + 1] == "'"):
            if char == "#":
                self.pos += 1
                char = "#'"
            if char == "," and self.source[self.pos:self.pos + 1] == "@":
                self.pos += 1
                char = ",@"
            child = self.read()
            return Form(start, child.end, "prefix", char, [child])
        if char == '"':
            while self.pos < len(self.source):
                char = self.source[self.pos]
                self.pos += 1
                if char == "\\":
                    self.pos += 1
                elif char == '"':
                    return Form(start, self.pos, "string")
            raise ValueError(f"unclosed string at offset {start}")
        if char == "?":
            # Character literals can contain quote/paren/string delimiters.
            if self.source[self.pos:self.pos + 1] == "\\":
                self.pos += 1
            self.pos += 1
        while self.pos < len(self.source):
            char = self.source[self.pos]
            if char.isspace() or char in "()[];'`\",":
                break
            self.pos += 2 if char == "\\" else 1
        return Form(start, self.pos, "atom", self.source[start:self.pos])

    def forms(self):
        result = []
        self.whitespace()
        while self.pos < len(self.source):
            result.append(self.read())
            self.whitespace()
        return result


class Migration:
    def __init__(self, source, callers=None, literal=False):
        self.source = source
        self.callers = set(callers) if callers else None
        self.literal = literal
        self.edits = []
        self.reviews = []

    def raw(self, node):
        return self.source[node.start:node.end]

    def review(self, node, reason):
        self.reviews.append((self.source.count("\n", 0, node.start) + 1, reason,
                             self.raw(node).replace("\n", " ")[:100]))
        return self.raw(node)

    @staticmethod
    def head(node):
        return node.children[0].text if node.kind == "list" and node.children else ""

    @staticmethod
    def numeric(node):
        return node.kind == "atom" and bool(NUMBER.fullmatch(node.text))

    def compose(self, node, replacements):
        result = self.raw(node)
        for child, value in reversed(replacements):
            left, right = child.start - node.start, child.end - node.start
            result = result[:left] + value + result[right:]
        return result

    def check_units(self, node, unit):
        """Report axis-invalid lengths, including nested function operands."""
        head = self.head(node)
        if node.kind == "prefix":
            self.review(node, "dynamic size operand; review its units on this axis")
        elif head in UNITS:
            if head not in AXIS_UNITS[unit]:
                reason = ("parent axis is unknown; review this length in its Flex context"
                          if unit is None else
                          "unit is invalid on this axis; allowed units: " +
                          ", ".join(sorted(AXIS_UNITS[unit])))
                self.review(node, reason)
        elif node.kind == "list":
            for child in node.children[1:]:
                self.check_units(child, unit)
        return self.raw(node)

    def scalar(self, node, unit, row_track=False):
        if node.kind == "prefix":
            if node.text in ("'", "`"):
                return self.compose(node, [(node.children[0], self.scalar(node.children[0], unit, row_track))])
            return self.review(node, "dynamic size; wrap the computed value in its explicit unit")
        if self.numeric(node):
            if unit is None:
                return self.review(node, "axis-dependent size; choose ch or lh from the parent layout")
            return f"({unit} {node.text})"
        if node.kind == "atom" and node.text in KEYWORDS:
            return self.raw(node)
        if node.text == "contain":
            return self.review(node, "contain was removed; choose the intended CSS sizing keyword")
        viewport = node.text if node.kind == "atom" else self.head(node)
        if viewport in ("viewport", "viewport-height"):
            if node.kind == "atom" or len(node.children) == 1:
                viewport_unit = "vw" if viewport == "viewport" else "vh"
                if viewport_unit not in AXIS_UNITS[unit]:
                    return self.review(node, "legacy viewport unit is invalid or ambiguous on this axis")
                return "(vw 100)" if viewport == "viewport" else "(vh 100)"
        if node.kind == "list" and len(node.children) == 1 and self.numeric(node.children[0]):
            child = node.children[0]
            if unit is None:
                return self.review(node, "axis-dependent singleton size; choose px or lh from the parent layout")
            if unit == "lh" and not row_track:
                return self.review(node, "ambiguous legacy block-axis singleton; choose explicit lh")
            # Legacy Grid rows interpreted singleton tracks as lines.
            return self.compose(node, [(child, ("lh " if row_track else "px ") + child.text)])
        head = self.head(node)
        if head in UNITS | FUNCTIONS:
            return self.check_units(node, unit)
        if head == "fit-content":
            return self.review(node, "parameterized fit-content was removed; choose keyword or min/max/clamp")
        return self.review(node, "unresolved size expression; manual migration required")

    def edges(self, node, axes, gap=False):
        if self.head(node) in UNITS | FUNCTIONS:
            for axis in dict.fromkeys(axes):
                self.check_units(node, axis)
            return self.raw(node)
        if node.kind != "list":
            if len(set(axes)) == 1:
                return self.scalar(node, axes[0])
            if self.numeric(node):
                return "(" + " ".join(self.scalar(node, axis) for axis in axes[:2]) + ")"
            return self.review(node, "dynamic shorthand; specify explicit edge units")
        parts = node.children
        if not 1 <= len(parts) <= len(axes) or parts[0].text.startswith(":"):
            return self.review(node, "unsupported edge shorthand; use CSS-ordered unit values")
        if len(parts) == 1 and len(set(axes)) > 1:
            if not self.numeric(parts[0]):
                return self.review(node, "ambiguous single edge shorthand; specify explicit edge units")
            child = parts[0]
            units = ["lh", "px"] if gap else axes[:2]
            return self.compose(node, [(child, " ".join(self.scalar(child, axis) for axis in units))])
        return self.compose(node, [(part, self.scalar(part, axes[i], row_track=gap and i == 0))
                                   for i, part in enumerate(parts)])

    def track(self, node, axis):
        head = self.head(node)
        if head == "fr":
            return self.raw(node)
        if head == "minmax" and len(node.children) == 3:
            return self.compose(node, [(part, self.track(part, axis)) for part in node.children[1:]])
        if head == "repeat" and len(node.children) == 3:
            body = node.children[2]
            if body.kind == "list" and not self.head(body) and len(body.children) > 1:
                new = self.tracks(body, axis)
            else:
                new = self.track(body, axis)
            return self.compose(node, [(body, new)])
        return self.scalar(node, axis, row_track=axis == "lh")

    def tracks(self, node, axis):
        if node.kind != "list" or self.head(node) in UNITS | FUNCTIONS | {"fr", "minmax", "repeat"}:
            return self.track(node, axis)
        return self.compose(node, [(part, self.track(part, axis)) for part in node.children])

    def value(self, prop, node, context, tag, parent_axis=None):
        if node.kind == "prefix":
            if node.text in ("'", "`"):
                child = node.children[0]
                return self.compose(node, [(child, self.value(prop, child, "data", tag, parent_axis))])
            return self.review(node, f"dynamic {prop}; manual migration required")
        if node.kind == "list" and self.head(node) == "quote" and len(node.children) == 2:
            child = node.children[1]
            return self.compose(node, [(child, self.value(prop, child, "data", tag, parent_axis))])
        if context == "code" and node.kind == "list":
            return self.review(node, f"computed {prop}; return an explicit unit value")
        if prop in {"max-width", "max-height"} and node.text == "auto":
            return self.review(node, "maximum sizes do not accept auto; choose none or an explicit size")
        if prop in {"padding", "margin", "border-width", "gap"} or prop in {
                "padding-inline", "padding-block", "margin-inline", "margin-block"}:
            if prop == "border-width":
                axes = ["px"] * 4
            elif prop.endswith("-inline"):
                axes = ["ch"] * 2
            elif prop.endswith("-block"):
                axes = ["lh"] * 2
            else:
                axes = ["lh", "ch"] * (1 if prop == "gap" else 2)
            result = self.edges(node, axes, gap=prop == "gap")
        elif prop == "border" or prop in {"border-top", "border-right", "border-bottom", "border-left"}:
            if node.kind == "string" or node.text in {"none", "solid", "nil"}:
                result = self.raw(node)
            elif node.kind == "list" and self.head(node) not in UNITS | FUNCTIONS:
                result = self.compose(node, [(part, self.scalar(part, "px"))
                                            for part in node.children
                                            if self.numeric(part) or self.head(part) in UNITS | FUNCTIONS])
            else:
                result = self.scalar(node, "px")
        elif prop == "flex":
            if node.kind == "atom":
                # Numbers here are unitless grow factors, not lengths.
                result = self.raw(node)
            elif len(node.children) == 3:
                basis = node.children[2]
                result = self.compose(node, [(basis, self.scalar(basis, parent_axis))])
            else:
                result = self.review(node, "unresolved flex shorthand; migrate only its basis size")
        elif prop.startswith("grid-"):
            result = self.tracks(node, "lh" if prop.endswith("rows") else "ch")
        else:
            axis = ("px" if prop.startswith("border-") else
                    "lh" if re.search(r"height|top|bottom|block|row-gap", prop) else "ch")
            if prop in {"item-gap", "flex-basis"}:
                axis = {"row": "ch", "column": "lh"}.get(tag) if prop == "item-gap" else parent_axis
            result = self.scalar(node, axis, row_track=prop == "row-gap")
        if context == "code" and result != self.raw(node) and result.startswith("("):
            result = "'" + result
        return result

    @staticmethod
    def property(node):
        if node.kind != "atom" or not node.text.startswith(":"):
            return None
        prop = node.text[1:]
        if re.fullmatch(r"(?:(?:min-|max-)?(?:width|height)|(?:padding|margin)(?:-(?:top|right|bottom|left|inline(?:-start|-end)?|block(?:-start|-end)?))?|border(?:-(?:top|right|bottom|left))?(?:-width)?|(?:row-|column-)?gap|item-gap|flex(?:-basis)?|grid-(?:template|auto)-(?:columns|rows))", prop):
            return prop
        return None

    def visit(self, node, context="code", in_scope=False, parent_axis=None):
        if node.kind == "prefix":
            self.visit(node.children[0], "data" if node.text in {"'", "`"} else "code", in_scope, parent_axis)
        elif node.kind == "list":
            children = node.children
            tag = self.head(node)
            child_axis = None
            if tag == "flex":
                child_axis = "ch"
                for i, child in enumerate(children[:-1]):
                    if child.text == ":flex-direction":
                        child_axis = {"row": "ch", "row-reverse": "ch",
                                      "column": "lh", "column-reverse": "lh"}.get(children[i + 1].text)
            elif tag not in {"box", "text", "row", "column", "grid"}:
                child_axis = parent_axis
            in_scope = in_scope or self.callers is None or self.head(node) in self.callers
            if self.head(node) == "styles":
                # ETAF's styles macro consumes its selector rules as data.
                context = "data"
            if self.head(node) in {"space", "image", "create-image"}:
                # Native Emacs display specs use their own pixel grammar.
                return
            if self.head(node) in {"quote", "backquote"} and len(children) == 2:
                self.visit(children[1], "data", in_scope, parent_axis)
                return
            i = 0
            while i < len(children):
                prop = self.property(children[i]) if in_scope else None
                if prop and i + 1 < len(children) and not children[i + 1].text.startswith(":"):
                    value = children[i + 1]
                    result = self.value(prop, value, context, tag, parent_axis)
                    if result != self.raw(value):
                        self.edits.append((value.start, value.end, result))
                    i += 2
                else:
                    self.visit(children[i], context, in_scope, child_axis)
                    i += 1

    def run(self):
        for form in Reader(self.source).forms():
            self.visit(form, "data" if self.literal else "code")
        output = self.source
        for start, end, value in sorted(self.edits, reverse=True):
            output = output[:start] + value + output[end:]
        return output


def paths_from(arguments):
    paths = set()
    for argument in arguments:
        path = Path(argument)
        if path.is_dir():
            for root, dirs, files in os.walk(path):
                dirs[:] = sorted(d for d in dirs if d not in SKIP_DIRS and not d.startswith("."))
                paths.update(Path(root, name) for name in files if Path(name).suffix in {".el", ".ebox", ".etaf", ".ecss"})
        else:
            paths.add(path)
    return sorted(paths)


def atomic_write(path, output):
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", newline="", dir=path.parent,
                                         prefix=".migrate-css-", delete=False) as stream:
            temporary = Path(stream.name)
            stream.write(output)
        temporary.chmod(path.stat().st_mode)
        os.replace(temporary, path)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--write", action="store_true", help="apply safe edits to the explicitly selected files")
    parser.add_argument("--callers", help="restrict edits/reviews to subforms rooted at these comma-separated API names")
    parser.add_argument("paths", nargs="+", help="Elisp/ebox or static etaf/ecss files, or directories containing public style callers")
    args = parser.parse_args(argv)
    changes = reviews = errors = count = 0
    for path in paths_from(args.paths):
        count += 1
        try:
            if path.is_symlink():
                raise ValueError("symlink inputs require selecting their actual target")
            with path.open(encoding="utf-8", newline="") as stream:
                source = stream.read()
            migration = Migration(source, args.callers.split(",") if args.callers else None,
                                  literal=path.suffix in {".etaf", ".ecss"})
            output = migration.run()
            changes += len(migration.edits)
            reviews += len(migration.reviews)
            if args.write and output != source:
                atomic_write(path, output)
            if migration.edits or migration.reviews:
                print(f"{path}: {len(migration.edits)} edits, {len(migration.reviews)} review items")
            for line, reason, snippet in migration.reviews:
                print(f"  {path}:{line}: REVIEW {reason}: {snippet}")
        except (OSError, UnicodeError, ValueError) as error:
            print(f"{path}: ERROR {error}", file=sys.stderr)
            errors += 1
    print(f"{'Applied' if args.write else 'Dry run'}: {count} files, {changes} property edits, {reviews} review items, {errors} errors")
    return 2 if errors else 1 if reviews else 0


if __name__ == "__main__":
    sys.exit(main())
