-- DOIR's language server for Neovim 0.11 or later. Put editors/nvim on the runtimepath and call vim.lsp.enable('doir'); `doir` must be on PATH.
return {
	cmd = { 'doir', '--lsp' },
	filetypes = { 'doir' },
	root_markers = { '.git' },
}
