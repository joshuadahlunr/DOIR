// Starts DOIR's language server, `doir --lsp`, for .doir files; `doir.serverPath` names the executable, and `doir.format` the formatter's options.
import * as vscode from "vscode";
import { LanguageClient, LanguageClientOptions, ServerOptions } from "vscode-languageclient/node";

let client: LanguageClient | undefined;

export async function activate(_context: vscode.ExtensionContext): Promise<void> {
	const command = vscode.workspace.getConfiguration("doir").get<string>("serverPath", "doir");
	const server: ServerOptions = { command, args: ["--lsp"] };
	// The server reads `doir.format` from its initialization options, then from each configuration change the client synchronizes.
	const options: LanguageClientOptions = {
		documentSelector: [{ language: "doir" }],
		initializationOptions: { format: vscode.workspace.getConfiguration("doir.format") },
		synchronize: { configurationSection: "doir" },
	};
	client = new LanguageClient("doir", "DOIR", server, options);
	await client.start();
}

export async function deactivate(): Promise<void> {
	await client?.stop();
}
