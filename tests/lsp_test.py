"""Drives `bin/doir --lsp` over the Language Server Protocol and checks what it answers (roadmap.md Phase 3): position encodings, diagnostics on open and after incremental edits, the store-backed requests, lifecycle and errors.

    uv run tests/lsp_test.py [path/to/doir]    # default bin/doir; exits 1 on the first failure
"""

import json
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent


class Client:
    """One `doir --lsp` process and the messages it sent that no check has consumed yet."""

    def __init__(self, server, encodings, initialization_options=None):
        self.process = subprocess.Popen([str(server), "--lsp"], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
        self.pending = []
        self.next_id = 1
        result = self.request("initialize", {"processId": None, "rootUri": None, "capabilities": {"general": {"positionEncodings": encodings}}, "initializationOptions": initialization_options})
        self.encoding = result["capabilities"]["positionEncoding"]
        self.capabilities = result["capabilities"]
        self.notify("initialized", {})

    def send(self, message):
        """Writes `message`, a dict or already-encoded bytes, framed."""
        body = message if isinstance(message, bytes) else json.dumps(message).encode()
        self.process.stdin.write(b"Content-Length: %d\r\n\r\n" % len(body) + body)
        self.process.stdin.flush()

    def receive(self):
        """Reads the next message the server sent."""
        length = None
        while True:
            line = self.process.stdout.readline()
            if not line:
                raise AssertionError("the server closed its output; check its stderr for why")
            if line in (b"\r\n", b"\n"):
                break
            name, _, value = line.decode().partition(":")
            if name.strip().lower() == "content-length":
                length = int(value)
        return json.loads(self.process.stdout.read(length))

    def wait(self, predicate):
        """The first message, pending or new, that `predicate` accepts; messages it skips stay pending."""
        for i, message in enumerate(self.pending):
            if predicate(message):
                return self.pending.pop(i)
        while True:
            message = self.receive()
            if predicate(message):
                return message
            self.pending.append(message)

    def request(self, method, params):
        """Sends a request and returns its result, failing on an error response."""
        id_ = self.next_id
        self.next_id += 1
        self.send({"jsonrpc": "2.0", "id": id_, "method": method, "params": params})
        response = self.wait(lambda m: m.get("id") == id_)
        if "error" in response:
            raise AssertionError(f"{method} failed: {response['error']}")
        return response["result"]

    def notify(self, method, params):
        """Sends a notification."""
        self.send({"jsonrpc": "2.0", "method": method, "params": params})

    def diagnostics(self, uri, version=None):
        """The next diagnostics published for `uri`, at `version` if given."""
        message = self.wait(lambda m: m.get("method") == "textDocument/publishDiagnostics" and m["params"]["uri"] == uri and (version is None or m["params"].get("version") == version))
        return message["params"]["diagnostics"]

    def close(self):
        """Shuts down and exits; returns the server's exit code."""
        self.request("shutdown", None)
        self.notify("exit", None)
        return self.process.wait(timeout=10)


def check(condition, what, hint):
    """Fails with what went wrong and how to look into it."""
    if not condition:
        raise AssertionError(f"{what}; {hint}")


def open_document(client, uri, text, version=1):
    """Opens `text` as `uri` and returns its first diagnostics."""
    client.notify("textDocument/didOpen", {"textDocument": {"uri": uri, "languageId": "doir", "version": version, "text": text}})
    return client.diagnostics(uri, version)


def change(client, uri, version, start, end, text):
    """Sends one incremental change replacing `start` to `end`, each (line, character), with `text`."""
    client.notify("textDocument/didChange", {"textDocument": {"uri": uri, "version": version}, "contentChanges": [{"range": {"start": {"line": start[0], "character": start[1]}, "end": {"line": end[0], "character": end[1]}}, "text": text}]})


def test_encodings_and_diagnostics(server):
    """The error after an astral character is at the column its encoding counts, with the parser's hint in the message."""
    text = 'ok : T = 1\ns : T = "\U0001F600"; bad : = 2\n'
    for offered, expected, column in ((["utf-16"], "utf-16", 20), (["utf-8", "utf-16"], "utf-8", 22)):
        client = Client(server, offered)
        check(client.encoding == expected, f"offered {offered}, the server chose {client.encoding}", "it should take utf-8 when offered and fall back to utf-16")
        check(client.capabilities["textDocumentSync"]["change"] == 2, "sync is not incremental", "initialize should answer textDocumentSync.change 2")
        diagnostics = open_document(client, "file:///tmp/enc.doir", text)
        check(len(diagnostics) == 1, f"expected one diagnostic, got {diagnostics}", "the second statement has no type")
        d = diagnostics[0]
        check(d["range"]["start"] == {"line": 1, "character": column}, f"{expected}: the error is at {d['range']['start']}, not line 1 character {column}", "positions after the emoji must count it as the encoding does")
        check(d["source"] == "doir" and d["severity"] == 1 and "\n" in d["message"], f"diagnostic lacks its source, severity or hint: {d}", "publish should append the parser's hint to the message")
        check(client.close() == 0, "the server did not exit cleanly after shutdown", "exit after shutdown should return 0")


def test_incremental_edits(server):
    """Incremental edits fix and break a file as committing its whole text would."""
    client = Client(server, ["utf-16"])
    uri = "file:///tmp/edit.doir"
    text = "ns : namespace = {\n\tx : = 1\n\ty : T = 2\n}\nz : T = 3\n"
    check(len(open_document(client, uri, text)) == 1, "the missing type was not reported", "x has no type")
    change(client, uri, 2, (1, 5), (1, 5), "T ")
    check(client.diagnostics(uri, 2) == [], "fixing the type left a diagnostic", "commitEdit must replace the block's errors")
    # The checks publish too: a value read above its binding is WF-Order, which reordering fixes.
    order_uri = "file:///tmp/order.doir"
    order = open_document(client, order_uri, "y : std.u8 = std.copy(std.u8, v)\nv : std.u8 = 5\n")
    check(len(order) == 1 and order[0].get("code") == "WF-Order" and order[0]["range"]["start"]["line"] == 0, f"the read above its binding published {order}", "WF-Order should be reported at the reading declaration, its tag as the code")
    change(client, order_uri, 2, (0, 0), (0, 0), "v : std.u8 = 5\n")
    change(client, order_uri, 3, (2, 0), (3, 0), "")
    check(client.diagnostics(order_uri, 3) == [], "moving the binding up left a diagnostic", "the checks must re-run when the block's entries change")
    change(client, uri, 3, (2, 4), (2, 6), "")
    after = client.diagnostics(uri, 3)
    fresh = open_document(client, "file:///tmp/fresh.doir", "ns : namespace = {\n\tx : T = 1\n\ty : = 2\n}\nz : T = 3\n")
    check(after == fresh, f"an edit published {after}, opening the same text {fresh}", "incremental and whole commits must agree")
    # A burst of edits ends on the last version's diagnostics.
    for version, at in ((4, 0), (5, 1), (6, 2)):
        change(client, uri, version, (4, at), (4, at), "q")
    check(client.diagnostics(uri, 6) is not None, "no diagnostics for the burst's last version", "publish once the burst is drained")
    client.notify("textDocument/didClose", {"textDocument": {"uri": uri}})
    # A closed document's diagnostics carry no version, which tells them from any the burst left pending.
    closed = client.wait(lambda m: m.get("method") == "textDocument/publishDiagnostics" and m["params"]["uri"] == uri and "version" not in m["params"])
    check(closed["params"]["diagnostics"] == [], "closing did not clear the document's diagnostics", "didClose should publish an empty list")
    check(client.close() == 0, "the server did not exit cleanly", "exit after shutdown should return 0")


def decode(data):
    """LSP's relative semantic-token integers as absolute (line, character, length, type) tuples."""
    tokens, line, character = [], 0, 0
    for i in range(0, len(data), 5):
        delta_line, delta_start, length, kind = data[i:i + 4]
        character = delta_start if delta_line else character + delta_start
        line += delta_line
        tokens.append((line, character, length, kind))
    return tokens


def apply_edits(text, edits):
    """`text`, ASCII, with LSP text edits applied, last first so earlier ranges stay put."""
    lines = text.split("\n")
    starts = [0]
    for line in lines:
        starts.append(starts[-1] + len(line) + 1)
    offset = lambda p: starts[p["line"]] + p["character"]
    for edit in sorted(edits, key=lambda e: offset(e["range"]["start"]), reverse=True):
        text = text[:offset(edit["range"]["start"])] + edit["newText"] + text[offset(edit["range"]["end"]):]
    return text


def test_features(server):
    """Highlighting by range agrees with the whole file's; outline, folding, definition, hover, selection ranges, signature help, completion, inlay hints, highlights, type definitions and workspace symbols read the store; comments fold; formatting lays out the whole file, a range or a line, as the doir.format settings say."""
    client = Client(server, ["utf-16"])
    uri = "file:///tmp/features.doir"
    text = "// a comment\nmath : namespace = {\n\tpi : f64 = 3.14 // the circle constant\n\ttwice : (x: f64) -> f64\n\tuse : f64 = pi\n\tdoubled : f64 = twice(pi)\n}\nouter : f64 = math.pi\n"
    check(open_document(client, uri, text) == [], "the sample has errors", "it should parse cleanly")
    legend = client.capabilities["semanticTokensProvider"]["legend"]["tokenTypes"]
    full = decode(client.request("textDocument/semanticTokens/full", {"textDocument": {"uri": uri}})["data"])
    ranged = decode(client.request("textDocument/semanticTokens/range", {"textDocument": {"uri": uri}, "range": {"start": {"line": 2, "character": 0}, "end": {"line": 4, "character": 0}}})["data"])
    check(ranged == [t for t in full if 2 <= t[0] <= 4], f"range tokens {ranged} differ from the full file's on lines 2-4", "range highlighting must lex from a token boundary")
    kinds = {(t[0], t[1]): legend[t[3]] for t in full}
    check(kinds[(0, 0)] == "comment" and kinds[(2, 1)] == "variable" and kinds[(2, 6)] == "type" and kinds[(2, 12)] == "number", f"tokens classified wrong: {kinds}", "names before `:`, types after it")
    symbols = client.request("textDocument/documentSymbol", {"textDocument": {"uri": uri}})
    check([s["name"] for s in symbols] == ["math", "outer"] and symbols[0]["kind"] == 3, f"outline {symbols}", "math is a namespace with outer after it")
    check([c["name"] for c in symbols[0]["children"]] == ["pi", "twice", "use", "doubled"] and symbols[0]["children"][1]["kind"] == 12, "math's children are wrong", "twice is a function")
    folds = client.request("textDocument/foldingRange", {"textDocument": {"uri": uri}})
    check(folds == [{"startLine": 1, "endLine": 6}], f"folding ranges {folds}", "the namespace folds from its first line to its `}`")
    target = client.request("textDocument/definition", {"textDocument": {"uri": uri}, "position": {"line": 4, "character": 14}})
    check(target and target["range"]["start"] == {"line": 2, "character": 1}, f"pi at use resolved to {target}", "a read inside math finds math's pi")
    target = client.request("textDocument/definition", {"textDocument": {"uri": uri}, "position": {"line": 7, "character": 18}})
    check(target and target["range"]["start"] == {"line": 2, "character": 1}, f"math.pi resolved to {target}", "a dotted name descends into math")
    hover = client.request("textDocument/hover", {"textDocument": {"uri": uri}, "position": {"line": 4, "character": 14}})
    check(hover and hover["contents"]["value"] == "```doir\npi : f64 = 3.14\n```\n\nthe circle constant", f"hover {hover}", "hover shows the declaration and its trailing comment")
    hover = client.request("textDocument/hover", {"textDocument": {"uri": uri}, "position": {"line": 1, "character": 0}})
    check(hover and hover["contents"]["value"] == "```doir\nmath : namespace = { … }\n```\n\na comment", f"hover {hover}", "hover shows a block's header, not its body, and the comment directly above it")
    ranges = client.request("textDocument/selectionRange", {"textDocument": {"uri": uri}, "positions": [{"line": 4, "character": 14}]})
    starts, level = [], ranges[0]
    while level:
        starts.append((level["range"]["start"]["line"], level["range"]["start"]["character"]))
        level = level.get("parent")
    check(starts == [(4, 13), (4, 1), (1, 0), (0, 0)], f"selection ranges start at {starts}", "pi, then use, then math, then the file")
    help_ = client.request("textDocument/signatureHelp", {"textDocument": {"uri": uri}, "position": {"line": 5, "character": 23}})
    check(help_ and help_["signatures"][0]["label"] == "twice(x: f64) -> f64" and help_["signatures"][0]["parameters"] == [{"label": "x: f64"}] and help_["activeParameter"] == 0, f"signature help {help_}", "inside twice( the signature comes from twice's function type")
    check(client.request("textDocument/signatureHelp", {"textDocument": {"uri": uri}, "position": {"line": 4, "character": 14}}) is None, "signature help outside a call", "a position in no call gets null")
    labels = lambda result: [item["label"] for item in result["items"]]
    near = client.request("textDocument/completion", {"textDocument": {"uri": uri}, "position": {"line": 4, "character": 14}})
    check(labels(near) == ["pi"], f"completing `p` inside math offered {labels(near)}", "names visible there starting with what is typed")
    members = client.request("textDocument/completion", {"textDocument": {"uri": uri}, "position": {"line": 7, "character": 19}})
    check(sorted(labels(members)) == ["doubled", "pi", "twice", "use"], f"completing `math.` offered {labels(members)}", "after a dot, the entries of the block the name before it resolves to")
    top = labels(client.request("textDocument/completion", {"textDocument": {"uri": uri}, "position": {"line": 7, "character": 14}}))
    check("math" in top and "outer" in top and "export" in top and "pi" not in top, f"completing at the root offered {top}", "the root's names and the keywords, not math's members")
    # A deduced parameter is never written at a call (D-Deduce), so arguments bind the parameters after it.
    deduce_uri = "file:///tmp/deduce.doir"
    open_document(client, deduce_uri, "pick : (T: deduced type, a: T, b: T) -> T\nr : f64 = pick(one, b)\none : f64 = 1\n")
    hints = client.request("textDocument/inlayHint", {"textDocument": {"uri": deduce_uri}, "range": {"start": {"line": 0, "character": 0}, "end": {"line": 3, "character": 0}}})
    check([(h["position"]["line"], h["position"]["character"], h["label"]) for h in hints] == [(1, 15, "a")], f"inlay hints {hints}", "each argument named after the parameter it binds, skipping T and arguments already named so")
    active = client.request("textDocument/signatureHelp", {"textDocument": {"uri": deduce_uri}, "position": {"line": 1, "character": 20}})
    check(active and active["activeParameter"] == 2, f"signature help {active}", "the second argument binds b, the third parameter")
    spots = lambda result: [(h["range"]["start"]["line"], h["range"]["start"]["character"], h["kind"]) for h in result]
    marks = client.request("textDocument/documentHighlight", {"textDocument": {"uri": uri}, "position": {"line": 4, "character": 14}})
    check(spots(marks) == [(2, 1, 3), (4, 13, 2), (5, 23, 2), (7, 19, 2)], f"highlights of pi {spots(marks)}", "pi's declaration as the write, its reads inside math and math.pi outside it")
    marks = client.request("textDocument/documentHighlight", {"textDocument": {"uri": uri}, "position": {"line": 7, "character": 15}})
    check(spots(marks) == [(1, 0, 3), (7, 14, 2)], f"highlights of math {spots(marks)}", "the cursor's segment of a dotted name is the one meant")
    found = client.request("workspace/symbol", {"query": "PI"})
    check([(f["name"], f.get("containerName")) for f in found] == [("pi", "math"), ("pick", None)], f"workspace symbols for PI {found}", "names containing the query, either case, in every open document, with their container")
    typed_uri = "file:///tmp/typed.doir"
    open_document(client, typed_uri, "point : type = { x : f64 ; }\np : point = 1\nq : f64 = p\n")
    target = client.request("textDocument/typeDefinition", {"textDocument": {"uri": typed_uri}, "position": {"line": 2, "character": 10}})
    check(target and target["range"]["start"] == {"line": 0, "character": 0}, f"type definition of p {target}", "p is declared a point")
    comments_uri = "file:///tmp/comments.doir"
    open_document(client, comments_uri, "// one\n// two\n# three\nx : T = 1 // trailing\n// four\n/* a\nb */\ny : T = 2\n")
    folds = client.request("textDocument/foldingRange", {"textDocument": {"uri": comments_uri}})
    check([(f["startLine"], f["endLine"], f.get("kind")) for f in folds] == [(0, 2, "comment"), (5, 6, "comment")], f"comment folds {folds}", "a run of comment lines and a block comment over two lines; a lone or trailing comment does not fold")
    messy_uri = "file:///tmp/messy.doir"
    messy = "n:namespace={\n  x:T=1\n\n\n  y : T = f( x )\n}\nm : namespace = {\n}\n"
    open_document(client, messy_uri, messy)
    whole = client.request("textDocument/formatting", {"textDocument": {"uri": messy_uri}, "options": {"tabSize": 4, "insertSpaces": False}})
    check(apply_edits(messy, whole) == "n : namespace = {\n\tx : T = 1\n\n\ty : T = f(x)\n}\nm : namespace = {\n}\n", f"formatting gave {apply_edits(messy, whole)!r}", "indent by braces, space punctuation as the corpus does, keep one blank line")
    ranged = client.request("textDocument/rangeFormatting", {"textDocument": {"uri": messy_uri}, "range": {"start": {"line": 4, "character": 0}, "end": {"line": 4, "character": 3}}, "options": {"tabSize": 4, "insertSpaces": False}})
    check(apply_edits(messy, ranged) == messy.replace("  y : T = f( x )", "\ty : T = f(x)"), f"range formatting gave {apply_edits(messy, ranged)!r}", "only the lines in the range change")
    typed = client.request("textDocument/onTypeFormatting", {"textDocument": {"uri": messy_uri}, "position": {"line": 1, "character": 7}, "ch": "}", "options": {"tabSize": 4, "insertSpaces": False}})
    check(apply_edits(messy, typed) == messy.replace("  x:T=1", "\tx : T = 1"), f"on-type formatting gave {apply_edits(messy, typed)!r}", "typing formats only the position's line")
    # The doir.format settings: semicolons become line breaks, and minifying applies to the whole file only.
    semis_uri = "file:///tmp/semis.doir"
    semis = "v : type = { x : f32 ; y : f32 ; }\nf : (a: T) -> T\n"
    open_document(client, semis_uri, semis)
    options = {"tabSize": 4, "insertSpaces": False}
    client.notify("workspace/didChangeConfiguration", {"settings": {"doir": {"format": {"semicolons": "newlinesAfterBraces"}}}})
    braces = client.request("textDocument/formatting", {"textDocument": {"uri": semis_uri}, "options": options})
    check(apply_edits(semis, braces) == "v : type = {\n\tx : f32\n\ty : f32\n}\nf : (a: T) -> T\n", f"newlinesAfterBraces gave {apply_edits(semis, braces)!r}", "each `;` and the `{` with a statement after it end their lines")
    client.notify("workspace/didChangeConfiguration", {"settings": {"doir": {"format": {"definitionColons": "attached", "parameterColons": "spaced", "braces": "nextLine"}}}})
    allman = client.request("textDocument/formatting", {"textDocument": {"uri": semis_uri}, "options": options})
    check(apply_edits(semis, allman) == "v: type =\n{\n\tx: f32\n\ty: f32\n}\nf: (a : T) -> T\n", f"attached definition colons, spaced parameter colons and nextLine braces gave {apply_edits(semis, allman)!r}", "no space before a definition's `:`, one before a parameter's, and the block's `{` on a line of its own")
    client.notify("workspace/didChangeConfiguration", {"settings": {"doir": {"format": {"definitionColons": "spaced", "parameterColons": "attached", "braces": "kept"}}}})
    client.notify("workspace/didChangeConfiguration", {"settings": {"doir": {"format": {"minify": True}}}})
    minified = client.request("textDocument/formatting", {"textDocument": {"uri": messy_uri}, "options": options})
    check(apply_edits(messy, minified) == "n:namespace={x:T=1;y:T=f(x);};m:namespace={};", f"minify gave {apply_edits(messy, minified)!r}", "one line, a `;` for each newline that ends a statement")
    ranged = client.request("textDocument/rangeFormatting", {"textDocument": {"uri": messy_uri}, "range": {"start": {"line": 4, "character": 0}, "end": {"line": 4, "character": 3}}, "options": options})
    check(apply_edits(messy, ranged) == messy.replace("  y : T = f( x )", "\ty : T = f(x)"), f"range formatting while minifying gave {apply_edits(messy, ranged)!r}", "minify applies to the whole document only")
    # A file the lexer cannot finish is not formatted, and the user is told why and where.
    broken_uri = "file:///tmp/broken.doir"
    open_document(client, broken_uri, "x : T = 1\ny : T = \"open\n")
    check(client.request("textDocument/formatting", {"textDocument": {"uri": broken_uri}, "options": options}) == [], "formatting a file with an unclosed string made edits", "it cannot trust the brackets")
    shown = client.wait(lambda m: m.get("method") == "window/showMessage")
    check(shown["params"]["type"] == 2 and "line 2" in shown["params"]["message"] and "fix it" in shown["params"]["message"], f"the refusal said {shown}", "a warning naming the line and how to fix it")
    settings = Client(server, ["utf-16"], {"format": {"semicolons": "newlines"}})
    open_document(settings, semis_uri, semis)
    lines = settings.request("textDocument/formatting", {"textDocument": {"uri": semis_uri}, "options": options})
    check(apply_edits(semis, lines) == "v : type = { x : f32\n\ty : f32\n}\nf : (a: T) -> T\n", f"initializationOptions newlines gave {apply_edits(semis, lines)!r}", "the server reads doir.format from initializationOptions too")
    check(settings.close() == 0, "the server did not exit cleanly", "exit after shutdown should return 0")
    check(client.close() == 0, "the server did not exit cleanly", "exit after shutdown should return 0")


def test_errors(server):
    """Unknown requests and malformed messages get JSON-RPC errors; exiting without shutdown exits 1."""
    client = Client(server, [])
    client.send({"jsonrpc": "2.0", "id": 99, "method": "textDocument/unknown", "params": {}})
    response = client.wait(lambda m: m.get("id") == 99)
    check(response.get("error", {}).get("code") == -32601, f"unknown method answered {response}", "requests the server does not handle get MethodNotFound")
    client.send(b"{not json")
    response = client.wait(lambda m: "error" in m and m.get("id") is None)
    check(response["error"]["code"] == -32700, f"malformed JSON answered {response}", "a message that does not parse gets ParseError")
    client.notify("exit", None)
    check(client.process.wait(timeout=10) == 1, "exit without shutdown did not return 1", "LSP's exit returns 1 unless shutdown came first")


def main():
    """Runs every check; returns 0 if all pass."""
    server = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / "bin" / "doir"
    tests = [test_encodings_and_diagnostics, test_incremental_edits, test_features, test_errors]
    for test in tests:
        try:
            test(server)
        except AssertionError as e:
            print(f"tests/lsp_test.py: {test.__name__}: {e}", file=sys.stderr)
            return 1
    print(f"lsp_test: all {len(tests)} checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
