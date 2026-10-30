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
                let options = viewModel.availableSuggestions(for: kind)
                if !options.isEmpty {
                    Menu(kind.addPrompt, systemImage: "plus.circle") {
                        ForEach(options, id: \.self) { option in
                            Button(option) { viewModel.add(option, to: kind) }
                        }
                    }
                }
            }
        }
    }
}

#Preview {
    Form { TagsSection(viewModel: EditTagsViewModel(item: PlexMetadata(ratingKey: "1", title: "Album", type: "album"))) }
}
