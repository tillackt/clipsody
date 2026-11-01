import AppKit
import ClipsodyCore
import UniformTypeIdentifiers

/// Export and import of the snippets, e.g. to move them to another Mac.
extension SettingsWindowController {
    func snippetsRow() -> NSStackView {
        let export = NSButton(title: String(localized: "Export…"), target: self, action: #selector(exportSnippets))
        let importButton = NSButton(title: String(localized: "Import…"), target: self, action: #selector(importSnippets))
        let stack = NSStackView(views: [export, importButton])
        stack.spacing = 12
        return stack
    }

    @objc func exportSnippets() {
        guard let window else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = String(localized: "Clipsody Snippets") + ".json"
        panel.allowedContentTypes = [.json]
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            do {
                try snippets.exportData().write(to: url, options: .atomic)
            } catch {
                inform(String(localized: "The snippets could not be exported."), error.localizedDescription)
            }
        }
    }

    @objc func importSnippets() {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            do {
                // Checked before reading: a huge file is not one of ours.
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                guard size <= 5 * 1024 * 1024 else { throw SnippetStore.Failure.unreadableFile }
                let added = try snippets.importData(Data(contentsOf: url))
                inform(String(localized: "Snippets imported"), added == 0
                    ? String(localized: "All snippets in the file were already there; nothing was added.")
                    : String(localized: "\(added) snippets added. Existing snippets were not changed."))
            } catch {
                inform(String(localized: "The file could not be imported."),
                       String(localized: "Choose a file exported from Clipsody’s snippets."))
            }
        }
    }

    private func inform(_ message: String, _ detail: String) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.beginSheetModal(for: window)
    }
}
