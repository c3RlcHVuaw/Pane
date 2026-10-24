import PaneModel
import SwiftUI

struct AssistantPane: View {
    @ObservedObject var settings: AppSettings
    let actions: SettingsActions
    @State private var key = ""
    @State private var hasKey = false
    @State private var testing = false
    @State private var testResult: (ok: Bool, text: String)?

    private let anthropicModels = ["claude-sonnet-5-5", "claude-opus-5-5", "claude-haiku-5-5", "claude-fable-5-1"]
    private let openAIModels = ["gpt-4o-mini", "gpt-4o"]
    private var isOpenAI: Bool { settings.assistantProvider == "openai" }

    var body: some View {
        Form {
            Section {
                Picker("Provider", selection: $settings.assistantProvider) {
                    Text("Anthropic (Claude)").tag("anthropic")
                    Text("OpenAI or compatible").tag("openai")
                }
                .accessibilityLabel("Provider")
                .onChange(of: settings.assistantProvider) { _, p in
                    settings.assistantModel = p == "openai" ? openAIModels[0] : anthropicModels[0]
                    testResult = nil
                }
                HStack {
                    TextField("Model", text: $settings.assistantModel).accessibilityLabel("Model name")
                    Menu {
                        ForEach(isOpenAI ? openAIModels : anthropicModels, id: \.self) { m in Button(m) { settings.assistantModel = m } }
                    } label: { Image(systemName: "chevron.up.chevron.down") }
                        .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Choose a common model")
                }
                if isOpenAI {
                    TextField("Server address", text: $settings.assistantBaseURL, prompt: Text("https://api.openai.com/v1"))
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Server address")
                }
            } header: { Text("Model") } footer: {
                Text(isOpenAI ? tr("Works with OpenAI, OpenRouter and local servers such as Ollama (http://localhost:11434/v1) and LM Studio.")
                              : tr("Pane talks to the Anthropic API directly from your Mac."))
            }

            Section {
                Toggle("Let the assistant control the browser (Act mode, experimental)", isOn: $settings.agentEnabled)
                Toggle("Ask before important actions", isOn: $settings.agentConfirm).disabled(!settings.agentEnabled)
                Toggle("Private mode: the agent works in a private tab", isOn: $settings.agentPrivate).disabled(!settings.agentEnabled)
            } header: { Text("Agent (Act mode)") } footer: {
                Text("In Act mode the assistant can control the browser. In private mode it works in a separate private tab and can't see your other tabs, bookmarks, history, notes, saved logins or “About me”. With ask-before on, you approve closing tabs, deleting bookmarks, changing settings and submitting forms. Whatever you choose, it never types passwords, card numbers or codes, and page text can't give it orders.")
            }

            Section {
                TextEditor(text: $settings.aboutMe)
                    .font(.system(size: 13)).frame(minHeight: 90)
                    .scrollContentBackground(.hidden)
                    .overlay(alignment: .topLeading) {
                        if settings.aboutMe.isEmpty {
                            Text("Name, e-mail, phone, city, languages, work experience, links…").foregroundStyle(.tertiary).padding(.top, 8).padding(.leading, 5).allowsHitTesting(false)
                        }
                    }
                    .accessibilityLabel("About me")
            } header: { Text("About me — for forms and applications") } footer: {
                Text("The agent can use this to fill in forms and write applications. It stays on this Mac, is sent to your AI provider only when the agent works, and never includes passwords.")
            }

            Section {
                HStack {
                    SecureField(hasKey ? "Key saved — paste a new one to replace it" : "API key", text: $key)
                        .textContentType(.password)
                        .accessibilityLabel("API key")
                        .onSubmit(saveKey)
                    if !key.isEmpty { Button("Save", action: saveKey).buttonStyle(.borderedProminent) }
                    else if hasKey { Button("Remove", role: .destructive) { actions.clearAssistantKey(); hasKey = false; testResult = nil } }
                }
                HStack {
                    Button { runTest() } label: {
                        if testing { ProgressView().controlSize(.small) } else { Text("Test Connection") }
                    }
                    .disabled(testing || (!hasKey && !isOpenAI))
                    if let r = testResult {
                        Label(r.text, systemImage: r.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(r.ok ? .green : .orange).font(.callout).lineLimit(2)
                    }
                    Spacer()
                }
            } header: { Text("API key") } footer: {
                Text("The key is stored in the macOS Keychain on this Mac and is never synced. Page text is sent to your provider only when you ask a question, and only for the pages you share.")
            }
        }
        .formStyle(.grouped)
        .onAppear { hasKey = actions.hasAssistantKey() }
    }

    private func saveKey() {
        guard !key.isEmpty else { return }
        actions.saveAssistantKey(key)
        key = ""; hasKey = true; testResult = nil
    }

    private func runTest() {
        testing = true; testResult = nil
        Task {
            let r = await actions.testAssistant()
            testResult = r
            testing = false
        }
    }
}
