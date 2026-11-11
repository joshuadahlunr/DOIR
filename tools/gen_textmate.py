"""Writes the VS Code extension's TextMate grammar, the highlighting a .doir file gets before the language server's semantic tokens arrive (roadmap.md Phase 3), with its keywords read from doir.peg so the two cannot drift.

	uv run tools/gen_textmate.py [output]    # default editors/vscode/syntaxes/doir.tmLanguage.json
"""

import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent


def keywords(grammar):
	"""The words of doir.peg's `Keywords` rule."""
	rule = re.search(r"^Keywords <- \(([^)]*)\)", grammar, re.MULTILINE)
	if rule is None:
		raise SystemExit("doir.peg: no `Keywords <- (...)` rule; tools/gen_textmate.py reads the keywords from it, so restore its form or update this tool")
	return re.findall(r"'([^']+)'", rule.group(1))


def tm_grammar(words):
	"""The TextMate grammar: comments, strings, numbers, keywords, source annotations, declaration names and the types after `:` or `->`."""
	identifier = r"(?:%\"[^\"]*\"|[A-Za-z_\u0080-￿][\w.\u0080-￿]*)"
	return {
		"$schema": "https://raw.githubusercontent.com/martinring/tmlanguage/master/tmlanguage.json",
		"name": "DOIR",
		"scopeName": "source.doir",
		"fileTypes": ["doir"],
		"patterns": [
			{"name": "comment.line.double-slash.doir", "match": r"(//|#).*$"},
			{"name": "comment.block.doir", "begin": r"/\*", "end": r"\*/"},
			{"name": "string.quoted.triple.doir", "begin": r"(\"{3,})", "end": r"\1"},
			{"name": "string.quoted.double.doir", "begin": "\"", "end": "\"", "patterns": [{"name": "constant.character.escape.doir", "match": r"\\."}]},
			{"name": "string.quoted.single.doir", "match": r"'(\\.|[^'\\])'"},
			{"name": "meta.preprocessor.source-annotation.doir", "match": r"<\"[^\"]*\":[^>]*>"},
			{"name": "keyword.other.doir", "match": r"\b(" + "|".join(map(re.escape, words)) + r")\b"},
			{"name": "constant.numeric.doir", "match": r"\b(0[xX][0-9a-fA-F_]+|0[bB][01_]+|[0-9][0-9_]*(\.[0-9_]+)?([eE][+-]?[0-9]+)?)\b"},
			{"match": r"^\s*(?:export\s+)?(" + identifier + r")\s*(?=:)", "captures": {"1": {"name": "variable.other.definition.doir"}}},
			{"match": r"(?:(?<=:)|(?<=->))\s*(" + identifier + r")", "captures": {"1": {"name": "entity.name.type.doir"}}},
			{"name": "keyword.operator.doir", "match": r"->|[:=,;]"},
		],
	}


def main():
	"""Writes the grammar; returns 0."""
	output = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / "editors/vscode/syntaxes/doir.tmLanguage.json"
	words = keywords((ROOT / "doir.peg").read_text())
	output.write_text(json.dumps(tm_grammar(words), indent="\t", ensure_ascii=False) + "\n")
	print(f"{output}: {len(words)} keywords")
	return 0


if __name__ == "__main__":
	sys.exit(main())
