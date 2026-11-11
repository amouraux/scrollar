import Foundation

// Where a key or a connection is made, and what to choose there, in one place so that every screen
// that asks for one says the same thing. Pure and tested; the screens only show it.

/// A page on another service's website, opened in the browser, with what to do there.
struct SetupPage: Equatable {
    var buttonTitle: String
    var url: URL
    /// What to choose or press there, in the order it is met. Plain sentences.
    var steps: [String]

    var guide: String { steps.joined(separator: " ") }
}

enum SetupHelp {
    /// OpenAlex asks for no more than an email address, and the key is free. Without one, Scrollar
    /// leaves OpenAlex out and the other sources answer.
    static let openAlex = SetupPage(
        buttonTitle: "Get a free key",
        url: URL(string: "https://openalex.org/settings/api")!,
        steps: ["Sign in at OpenAlex with your email address, then copy the key from that page and paste it here."])

    /// What the app uses of a Zotero library, which decides what the key must allow: reading the newest
    /// items to learn from (library access), and adding a paper and its PDF (write access). Notes and
    /// group libraries are never read.
    static func zotero(needsWrite: Bool) -> SetupPage {
        var steps = ["Sign in at zotero.org, name the key Scrollar, and under Personal library tick Allow library access."]
        steps.append(needsWrite
                     ? "Also tick Allow write access, which Add to Zotero needs."
                     : "Also tick Allow write access if you want Add to Zotero; to only learn from your library, leave it off.")
        steps.append("Leave Allow notes access and the group permissions off, then press Save Key and copy the key it shows.")
        return SetupPage(buttonTitle: "Create a key on zotero.org",
                         url: URL(string: "https://www.zotero.org/settings/keys/new")!, steps: steps)
    }

    /// For a key that can only read: the page where a key's access is changed.
    static let zoteroKeys = SetupPage(
        buttonTitle: "Change the key's access on zotero.org",
        url: URL(string: "https://www.zotero.org/settings/keys")!,
        steps: ["Open Scrollar's key, tick Allow write access under Personal library and save it, then check the connection here."])

    /// A Claude or ChatGPT key is a separate pay-per-use account. A chat subscription does not include one.
    static func summaries(_ provider: SummaryProvider) -> SetupPage? {
        switch provider {
        case .anthropic:
            return SetupPage(buttonTitle: "Get a Claude API key",
                             url: URL(string: "https://console.anthropic.com/settings/keys")!,
                             steps: ["In the Claude Console choose Create key, name it Scrollar and copy it when it is shown; it is shown once.",
                                     "The account needs a few dollars of credit, separate from a Claude chat subscription."])
        case .openai:
            return SetupPage(buttonTitle: "Get an OpenAI API key",
                             url: URL(string: "https://platform.openai.com/api-keys")!,
                             steps: ["On the OpenAI platform choose Create new secret key, name it Scrollar and copy it when it is shown; it is shown once.",
                                     "The account needs a few dollars of credit, separate from a ChatGPT subscription."])
        case .other:
            return nil
        }
    }
}
