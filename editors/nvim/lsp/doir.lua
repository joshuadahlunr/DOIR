-- DOIR's language server for Neovim 0.11 or later. Put editors/nvim on the runtimepath and call vim.lsp.enable('doir'); `doir` must be on PATH. Override `settings.doir.format` with vim.lsp.config('doir', { settings = ... }): `minify` writes the file on one line, `semicolons` is 'kept', 'newlines' or 'newlinesAfterBraces', `definitionColons` and `parameterColons` are 'spaced' or 'attached', and `braces` is 'kept', 'sameLine' or 'nextLine'.
return {
	cmd = { 'doir', '--lsp' },
	filetypes = { 'doir' },
	root_markers = { '.git' },
	settings = { doir = { format = { minify = false, semicolons = 'kept', definitionColons = 'spaced', parameterColons = 'attached', braces = 'kept' } } },
}
