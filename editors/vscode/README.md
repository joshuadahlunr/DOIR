# DOIR for Visual Studio Code

Language support for `.doir` files: syntax highlighting, filetype settings, and the compiler's language server, `doir --lsp`, for diagnostics, completion, hover, go-to-definition and formatting.

## Requirements

- Visual Studio Code 1.90 or later.
- The `doir` executable, with `--lsp` support, on `PATH`.

Build the compiler from the repository root:

```sh
dub build --config=doir --compiler=ldc2
```

This writes `bin/doir`.
Put that directory on your `PATH`, or leave it off and point the extension at the binary with `doir.serverPath`.

## Install

### From the packaged extension

The repository contains a built `doir-0.1.0.vsix`.
Install it with:

```sh
code --install-extension editors/vscode/doir-0.1.0.vsix
```

Or, in VS Code, run **Extensions: Install from VSIX...** and pick the file.

### From source

```sh
cd editors/vscode
npm install
npm run package        # builds out/extension.js and writes a .vsix
code --install-extension doir-0.1.0.vsix
```

For development, run `npm run build` and press `F5` to open an Extension Development Host with the extension loaded.
`npm run check` type-checks it.

After installing, open a `.doir` file and check the **Output** panel, channel **DOIR**, to confirm the language server started.

## Configuration

The extension contributes these settings under `doir`:

| Setting | Default | Meaning |
| --- | --- | --- |
| `doir.serverPath` | `doir` | The executable run as `doir --lsp`. Use an absolute path if `doir` is not on `PATH`. |
| `doir.format.minify` | `false` | Format Document writes the file on one line; comments, indentation and blank lines go, and a statement-ending newline becomes `;`. Range and on-type formatting ignore it. |
| `doir.format.semicolons` | `kept` | What formatting does with a `;` that ends a statement: `kept`, `newlines` or `newlinesAfterBraces`. |
| `doir.format.definitionColons` | `spaced` | Whether a definition's `:` has a space before it: `spaced` (`name : type`) or `attached` (`name: type`). |
| `doir.format.parameterColons` | `attached` | Whether a parameter's `:` has a space before it: `spaced` (`a : T`) or `attached` (`a: T`). |
| `doir.format.braces` | `kept` | Where formatting puts a block's `{`: `kept`, `sameLine` or `nextLine`. |

Formatting is **Format Document** (`Shift+Alt+F`), `editor.formatOnSave`, or `editor.formatOnType`.
