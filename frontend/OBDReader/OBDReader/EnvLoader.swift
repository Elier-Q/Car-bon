import Foundation

class EnvLoader {
    static func loadEnv() -> [String: String] {
        guard let envPath = Bundle.main.path(forResource: ".env", ofType: nil),
              let content = try? String(contentsOfFile: envPath) else {
            print("⚠️ .env file not found in bundle")
            return [:]
        }

        var dict: [String: String] = [:]
        for line in content.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let parts = trimmed.split(separator: "=", maxSplits: 1)
            if parts.count == 2 {
                dict[String(parts[0])] = String(parts[1])
            }
        }
        return dict
    }
}
