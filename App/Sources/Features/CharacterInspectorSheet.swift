import SwiftUI
import CharacterInfo

struct CharacterInspectorSheet: View {

    let text: String
    let range: NSRange

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                if let info = inspectedInfo {
                    VStack(alignment: .leading, spacing: 16) {
                        glyphCard(info)
                        scalarTable(info)
                    }
                    .padding()
                } else {
                    ContentUnavailableView(
                        "No Character Selected",
                        systemImage: "character.cursor.ibeam",
                        description: Text("Select one or more characters in the editor to inspect them.")
                    )
                    .padding(.top, 60)
                }
            }
            .navigationTitle("Character Inspector")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var inspectedInfo: [CharacterInfo]? {
        guard let stringRange = Range(range, in: text), !stringRange.isEmpty else { return nil }
        let substring = text[stringRange]
        let infos = substring.map { CharacterInfo(character: $0) }
        return infos.isEmpty ? nil : infos
    }

    @ViewBuilder
    private func glyphCard(_ infos: [CharacterInfo]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Glyph")
                .font(.headline)
            Text(infos.map(\.character).map(String.init).joined())
                .font(.system(size: 72))
                .frame(maxWidth: .infinity, alignment: .center)
                .padding()
                .background(Color.gray.opacity(0.1))
                .clipShape(.rect(cornerRadius: 12))
        }
    }

    @ViewBuilder
    private func scalarTable(_ infos: [CharacterInfo]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Unicode Scalars")
                .font(.headline)
            ForEach(Array(infos.enumerated()), id: \.offset) { _, info in
                VStack(alignment: .leading, spacing: 4) {
                    Text(String(info.character))
                        .font(.system(size: 28))
                    Text(info.description)
                        .font(.body)
                        .foregroundStyle(.primary)
                    ForEach(Array(String(info.character).unicodeScalars), id: \.value) { scalar in
                        HStack {
                            Text(String(format: "U+%04X", scalar.value))
                                .font(.system(.body, design: .monospaced))
                            Spacer()
                            Text(scalar.properties.name ?? "—")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.gray.opacity(0.06))
                .clipShape(.rect(cornerRadius: 8))
            }
        }
    }
}
