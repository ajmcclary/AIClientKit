import Foundation

/// Bounds how many fetched model ids an OpenAI-compatible endpoint folds into `enabledModels`.
/// Above `autoEnableThreshold`, only explicitly-required models (default + user-selected) are kept,
/// so a huge catalog (e.g. Featherless's ~42k) never reaches the model lists / catalog / picker.
/// The rest stay reachable through the search browser.
public enum AIModelListCap {
    public static let autoEnableThreshold = 200

    public static func enabledModels(fetched: [String], threshold: Int = autoEnableThreshold, required: [String]) -> Set<String> {
        func clean(_ xs: [String]) -> Set<String> {
            Set(xs.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
        }
        let req = clean(required)
        let all = clean(fetched)
        if all.count <= threshold { return all.union(req) }
        return req
    }
}
