# DOIR for Neovim

Language support for `.doir` files: filetype detection, `//` comments, and the compiler's language server, `doir --lsp`, for diagnostics, completion, hover, go-to-definition and formatting.

## Requirements

- Neovim 0.11 or later (the plugin uses `vim.lsp.enable`).
- The `doir` executable, with `--lsp` support, on `PATH`.

Build the compiler from the repository root:

```sh
dub build --config=doir --compiler=ldc2
```

This writes `bin/doir`.
Put that directory on your `PATH`, or point the server at the binary with `cmd` (see below).

## Install

Add `editors/nvim` to your runtimepath.
With a plugin manager, use this directory as the plugin:

```lua
-- lazy.nvim
{
    dir = '~/Dev/DOIRprototype/editors/nvim',
    ft = 'doir',
    config = function()
        vim.lsp.enable('doir')
    end,
}
```

Without a plugin manager, prepend the directory in your `init.lua` before enabling the server:

```lua
vim.opt.runtimepath:prepend('~/Dev/DOIRprototype/editors/nvim')
vim.lsp.enable('doir')
```

Restart Neovim, open a `.doir` file, and check that the client attached with `:checkhealth vim.lsp`.

## Configuration

The server is configured under `settings.doir`.
Every value below is the default:

```lua
vim.lsp.config('doir', {
    cmd = { 'doir', '--lsp' },
    settings = {
        doir = {
            format = {
                minify = false,           -- write the file on one line
                semicolons = 'kept',      -- 'kept' | 'newlines' | 'newlinesAfterBraces'
                definitionColons = 'spaced',  -- 'spaced' | 'attached'
                parameterColons = 'attached', -- 'spaced' | 'attached'
                braces = 'kept',          -- 'kept' | 'sameLine' | 'nextLine'
            },
        },
    },
})
vim.lsp.enable('doir')
```

Formatting is `vim.lsp.buf.format()`, or `gq` if you map it:

```lua
vim.keymap.set('n', 'gq', function()
    vim.lsp.buf.format({ async = true })
end, { desc = 'Format buffer' })
```
