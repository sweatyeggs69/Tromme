import SwiftUI

struct TagsSection: View {
    @Bindable var viewModel: EditTagsViewModel

    var body: some View {
        ForEach(TagKind.allCases, id: \.self) { kind in
            Section(kind.title) {
                ForEach(viewModel.tags[kind] ?? [], id: \.self) { tag in
                    Text(tag)
                }
                .onDelete { viewModel.remove(kind, at: $0) }
                HStack {
                    TextField(kind.addPrompt, text: draft(kind))
                        .submitLabel(.done)
                        .onSubmit { viewModel.commitDraft(kind) }
                    let options = viewModel.availableSuggestions(for: kind)
                    if !options.isEmpty {
                        Menu("Choose", systemImage: "plus.circle") {
                            ForEach(options, id: \.self) { option in
                                Button(option) { viewModel.add(option, to: kind) }
                            }
                        }
                        .labelStyle(.iconOnly)
                    }
                }
            }
        }
    }

    private func draft(_ kind: TagKind) -> Binding<String> {
        Binding(
            get: { viewModel.drafts[kind] ?? "" },
            set: { viewModel.drafts[kind] = $0 }
        )
    }
}

#Preview {
    Form { TagsSection(viewModel: EditTagsViewModel(item: PlexMetadata(ratingKey: "1", title: "Album", type: "album"))) }
}
