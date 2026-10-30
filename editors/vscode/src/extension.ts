// Starts DOIR's language server, `doir --lsp`, for .doir files; `doir.serverPath` names the executable.
import * as vscode from "vscode";
import { LanguageClient, LanguageClientOptions, ServerOptions } from "vscode-languageclient/node";

let client: LanguageClient | undefined;

export async function activate(_context: vscode.ExtensionContext): Promise<void> {
	const command = vscode.workspace.getConfiguration("doir").get<string>("serverPath", "doir");
	const server: ServerOptions = { command, args: ["--lsp"] };
	const options: LanguageClientOptions = { documentSelector: [{ language: "doir" }] };
	client = new LanguageClient("doir", "DOIR", server, options);
	await client.start();
}

export async function deactivate(): Promise<void> {
	await client?.stop();
}
